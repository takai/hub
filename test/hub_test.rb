require 'helper'
require 'webmock/test_unit'
require 'rbconfig'
require 'yaml'
require 'forwardable'

WebMock::BodyPattern.class_eval do
  undef normalize_hash
  # override normalizing hash since it otherwise requires JSON
  def normalize_hash(hash) hash end
end

class HubTest < Test::Unit::TestCase
  extend Forwardable

  if defined? WebMock::API
    include WebMock::API
  else
    include WebMock
  end

  COMMANDS = []

  Hub::Context.class_eval do
    remove_method :which
    define_method :which do |name|
      COMMANDS.include?(name) ? "/usr/bin/#{name}" : nil
    end
  end

  attr_reader :git_reader
  include Hub::Context::GitReaderMethods
  def_delegators :git_reader, :stub_config_value, :stub_command_output

  def setup
    super
    COMMANDS.replace %w[open groff]
    Hub::Context::PWD.replace '/path/to/hub'
    Hub::Context::SshConfig::CONFIG_FILES.replace []

    @git_reader = Hub::Context::GitReader.new 'git' do |cache, cmd|
      unless cmd.index('config --get alias.') == 0
        raise ArgumentError, "`git #{cmd}` not stubbed"
      end
    end

    Hub::Commands.instance_variable_set :@git_reader, @git_reader
    Hub::Commands.instance_variable_set :@local_repo, nil

    @git_reader.stub! \
      'remote' => "mislav\norigin",
      'symbolic-ref -q HEAD' => 'refs/heads/master',
      'config --get github.user'   => 'tpw',
      'config --get github.token'  => 'abc123',
      'config --get-all remote.origin.url' => 'git://github.com/defunkt/hub.git',
      'config --get-all remote.mislav.url' => 'git://github.com/mislav/hub.git',
      'rev-parse --symbolic-full-name master@{upstream}' => 'refs/remotes/origin/master',
      'config --get --bool hub.http-clone' => 'false',
      'config --get hub.protocol' => nil,
      'config --get-all hub.host' => nil,
      'rev-parse -q --git-dir' => '.git'
  end

  def test_private_clone
    stub_no_git_repo
    input   = "clone -p rtomayko/ronn"
    command = "git clone git@github.com:rtomayko/ronn.git"
    assert_command input, command
  end

  def test_private_clone_noop
    stub_no_git_repo
    input   = "--noop clone -p rtomayko/ronn"
    command = "git clone git@github.com:rtomayko/ronn.git\n"
    assert_output command, hub(input)
  end

  def test_https_clone
    stub_no_git_repo
    stub_https_is_preferred
    input   = "clone rtomayko/ronn"
    command = "git clone https://github.com/rtomayko/ronn.git"
    assert_command input, command
  end

  def test_public_clone
    stub_no_git_repo
    input   = "clone rtomayko/ronn"
    command = "git clone git://github.com/rtomayko/ronn.git"
    assert_command input, command
  end

  def test_your_private_clone
    stub_no_git_repo
    input   = "clone -p resque"
    command = "git clone git@github.com:tpw/resque.git"
    assert_command input, command
  end

  def test_your_clone_is_always_private
    stub_no_git_repo
    input   = "clone resque"
    command = "git clone git@github.com:tpw/resque.git"
    assert_command input, command
  end

  def test_clone_repo_with_period
    stub_no_git_repo
    input   = "clone hookio/hook.js"
    command = "git clone git://github.com/hookio/hook.js.git"
    assert_command input, command
  end

  def test_clone_with_arguments
    stub_no_git_repo
    input   = "clone --bare -o master resque"
    command = "git clone --bare -o master git@github.com:tpw/resque.git"
    assert_command input, command
  end

  def test_clone_with_arguments_and_destination
    stub_no_git_repo
    assert_forwarded "clone --template=one/two git://github.com/tpw/resque.git --origin master resquetastic"
  end

  def test_your_private_clone_fails_without_config
    stub_no_git_repo
    out = hub("clone -p mustache") do
      stub_github_user(nil)
    end

    assert_equal "** No GitHub user set. See http://help.github.com/set-your-user-name-email-and-github-token/\n", out
  end

  def test_your_public_clone_fails_without_config
    stub_no_git_repo
    out = hub("clone mustache") do
      stub_github_user(nil)
    end

    assert_equal "** No GitHub user set. See http://help.github.com/set-your-user-name-email-and-github-token/\n", out
  end

  def test_private_clone_left_alone
    stub_no_git_repo
    assert_forwarded "clone git@github.com:rtomayko/ronn.git"
  end

  def test_public_clone_left_alone
    stub_no_git_repo
    assert_forwarded "clone git://github.com/rtomayko/ronn.git"
  end

  def test_normal_public_clone_with_path
    stub_no_git_repo
    assert_forwarded "clone git://github.com/rtomayko/ronn.git ronn-dev"
  end

  def test_normal_clone_from_path
    stub_no_git_repo
    assert_forwarded "clone ./test"
  end

  def test_unchanged_clone_from_existing_directory
    stub_no_git_repo
    assert_forwarded "clone test"
  end

  def test_local_clone_with_destination
    stub_no_git_repo
    assert_forwarded "clone -l . ../copy"
  end

  def test_clone_with_host_alias
    stub_no_git_repo
    assert_forwarded "clone server:git/repo.git"
  end

  def test_enterprise_clone
    stub_no_git_repo
    stub_github_user('myfiname', 'git.my.org')
    with_host_env('git.my.org') do
      assert_command "clone myrepo", "git clone git@git.my.org:myfiname/myrepo.git"
      assert_command "clone another/repo", "git clone git@git.my.org:another/repo.git"
    end
  end

  def test_alias_expand
    stub_alias 'c', 'clone --bare'
    input   = "c rtomayko/ronn"
    command = "git clone --bare git://github.com/rtomayko/ronn.git"
    assert_command input, command
  end

  def test_alias_expand_advanced
    stub_alias 'c', 'clone --template="white space"'
    input   = "c rtomayko/ronn"
    command = "git clone '--template=white space' git://github.com/rtomayko/ronn.git"
    assert_command input, command
  end

  def test_alias_doesnt_expand_for_unknown_commands
    stub_alias 'c', 'compute --fast'
    assert_forwarded "c rtomayko/ronn"
  end

  def test_remote_origin
    input   = "remote add origin"
    command = "git remote add origin git://github.com/tpw/hub.git"
    assert_command input, command
  end

  def test_remote_add_with_name
    input   = "remote add another hookio/hub.js"
    command = "git remote add another git://github.com/hookio/hub.js.git"
    assert_command input, command
  end

  def test_private_remote_origin
    input   = "remote add -p origin"
    command = "git remote add origin git@github.com:tpw/hub.git"
    assert_command input, command
  end

  def test_public_remote_url_untouched
    assert_forwarded "remote add origin http://github.com/defunkt/resque.git"
  end

  def test_private_remote_url_untouched
    assert_forwarded "remote add origin git@github.com:defunkt/resque.git"
  end

  def test_remote_from_rel_path
    assert_forwarded "remote add origin ./path"
  end

  def test_remote_from_abs_path
    assert_forwarded "remote add origin /path"
  end

  def test_remote_with_host_alias
    assert_forwarded "remote add origin server:/git/repo.git"
  end

  def test_remote_add_enterprise
    stub_hub_host('git.my.org')
    stub_repo_url('git@git.my.org:defunkt/hub.git')
    assert_command "remote add another", "git remote add another git@git.my.org:another/hub.git"
  end

  def test_public_submodule
    input   = "submodule add wycats/bundler vendor/bundler"
    command = "git submodule add git://github.com/wycats/bundler.git vendor/bundler"
    assert_command input, command
  end

  def test_private_submodule
    input   = "submodule add -p grit vendor/grit"
    command = "git submodule add git@github.com:tpw/grit.git vendor/grit"
    assert_command input, command
  end

  def test_submodule_branch
    input   = "submodule add -b ryppl ryppl/pip vendor/pip"
    command = "git submodule add -b ryppl git://github.com/ryppl/pip.git vendor/pip"
    assert_command input, command
  end

  def test_submodule_with_args
    input   = "submodule -q add --bare -- grit grit"
    command = "git submodule -q add --bare -- git://github.com/tpw/grit.git grit"
    assert_command input, command
  end

  def test_private_remote
    input   = "remote add -p rtomayko"
    command = "git remote add rtomayko git@github.com:rtomayko/hub.git"
    assert_command input, command
  end

  def test_https_protocol_remote
    stub_https_is_preferred
    input   = "remote add rtomayko"
    command = "git remote add rtomayko https://github.com/rtomayko/hub.git"
    assert_command input, command
  end

  def test_public_remote
    input   = "remote add rtomayko"
    command = "git remote add rtomayko git://github.com/rtomayko/hub.git"
    assert_command input, command
  end

  def test_public_remote_f
    input   = "remote add -f rtomayko"
    command = "git remote add -f rtomayko git://github.com/rtomayko/hub.git"
    assert_command input, command
  end

  def test_named_public_remote
    input   = "remote add origin rtomayko"
    command = "git remote add origin git://github.com/rtomayko/hub.git"
    assert_command input, command
  end

  def test_named_public_remote_f
    input   = "remote add -f origin rtomayko"
    command = "git remote add -f origin git://github.com/rtomayko/hub.git"
    assert_command input, command
  end

  def test_private_remote_with_repo
    input   = "remote add -p jashkenas/coffee-script"
    command = "git remote add jashkenas git@github.com:jashkenas/coffee-script.git"
    assert_command input, command
  end

  def test_public_remote_with_repo
    input   = "remote add jashkenas/coffee-script"
    command = "git remote add jashkenas git://github.com/jashkenas/coffee-script.git"
    assert_command input, command
  end

  def test_public_remote_f_with_repo
    input   = "remote add -f jashkenas/coffee-script"
    command = "git remote add -f jashkenas git://github.com/jashkenas/coffee-script.git"
    assert_command input, command
  end

  def test_named_private_remote_with_repo
    input   = "remote add -p origin jashkenas/coffee-script"
    command = "git remote add origin git@github.com:jashkenas/coffee-script.git"
    assert_command input, command
  end

  def test_fetch_existing_remote
    assert_forwarded "fetch mislav"
  end

  def test_fetch_new_remote
    stub_remotes_group('xoebus', nil)
    stub_existing_fork('xoebus')

    assert_commands "git remote add xoebus git://github.com/xoebus/hub.git",
                    "git fetch xoebus",
                    "fetch xoebus"
  end

  def test_fetch_new_remote_https_protocol
    stub_remotes_group('xoebus', nil)
    stub_existing_fork('xoebus')
    stub_https_is_preferred

    assert_commands "git remote add xoebus https://github.com/xoebus/hub.git",
                    "git fetch xoebus",
                    "fetch xoebus"
  end

  def test_fetch_no_auth
    stub_github_user nil
    stub_github_token nil
    stub_remotes_group('xoebus', nil)
    # stub_existing_fork('xoebus')
    stub_request(:get, "https://github.com/api/v2/yaml/repos/show/xoebus/hub").
      to_return(:status => 200)

    assert_commands "git remote add xoebus git://github.com/xoebus/hub.git",
                    "git fetch xoebus",
                    "fetch xoebus"
  end

  def test_fetch_new_remote_with_options
    stub_remotes_group('xoebus', nil)
    stub_existing_fork('xoebus')

    assert_commands "git remote add xoebus git://github.com/xoebus/hub.git",
                    "git fetch --depth=1 --prune xoebus",
                    "fetch --depth=1 --prune xoebus"
  end

  def test_fetch_multiple_new_remotes
    stub_remotes_group('xoebus', nil)
    stub_remotes_group('rtomayko', nil)
    stub_existing_fork('xoebus')
    stub_existing_fork('rtomayko')

    assert_commands "git remote add xoebus git://github.com/xoebus/hub.git",
                    "git remote add rtomayko git://github.com/rtomayko/hub.git",
                    "git fetch --multiple xoebus rtomayko",
                    "fetch --multiple xoebus rtomayko"
  end

  def test_fetch_multiple_comma_separated_remotes
    stub_remotes_group('xoebus', nil)
    stub_remotes_group('rtomayko', nil)
    stub_existing_fork('xoebus')
    stub_existing_fork('rtomayko')

    assert_commands "git remote add xoebus git://github.com/xoebus/hub.git",
                    "git remote add rtomayko git://github.com/rtomayko/hub.git",
                    "git fetch --multiple xoebus rtomayko",
                    "fetch xoebus,rtomayko"
  end

  def test_fetch_multiple_new_remotes_with_filtering
    stub_remotes_group('xoebus', nil)
    stub_remotes_group('mygrp', 'one two')
    stub_remotes_group('typo', nil)
    stub_existing_fork('xoebus')
    stub_nonexisting_fork('typo')

    # mislav: existing remote; skipped
    # xoebus: new remote, fork exists; added
    # mygrp:  a remotes group; skipped
    # URL:    can't be a username; skipped
    # typo:   fork doesn't exist; skipped
    assert_commands "git remote add xoebus git://github.com/xoebus/hub.git",
                    "git fetch --multiple mislav xoebus mygrp git://example.com typo",
                    "fetch --multiple mislav xoebus mygrp git://example.com typo"
  end

  def test_cherry_pick
    assert_forwarded "cherry-pick a319d88"
  end

  def test_cherry_pick_url
    url = 'http://github.com/mislav/hub/commit/a319d88'
    assert_commands "git fetch mislav", "git cherry-pick a319d88", "cherry-pick #{url}"
  end

  def test_cherry_pick_url_with_fragment
    url = 'http://github.com/mislav/hub/commit/abcdef0123456789#comments'
    assert_commands "git fetch mislav", "git cherry-pick abcdef0123456789", "cherry-pick #{url}"
  end

  def test_cherry_pick_url_with_remote_add
    url = 'https://github.com/xoebus/hub/commit/a319d88'
    assert_commands "git remote add -f xoebus git://github.com/xoebus/hub.git",
                    "git cherry-pick a319d88",
                    "cherry-pick #{url}"
  end

  def test_cherry_pick_origin_url
    url = 'https://github.com/defunkt/hub/commit/a319d88'
    assert_commands "git fetch origin", "git cherry-pick a319d88", "cherry-pick #{url}"
  end

  def test_cherry_pick_github_user_notation
    assert_commands "git fetch mislav", "git cherry-pick 368af20", "cherry-pick mislav@368af20"
  end

  def test_cherry_pick_github_user_repo_notation
    # not supported
    assert_forwarded "cherry-pick mislav/hubbub@a319d88"
  end

  def test_cherry_pick_github_notation_too_short
    assert_forwarded "cherry-pick mislav@a319"
  end

  def test_cherry_pick_github_notation_with_remote_add
    assert_commands "git remote add -f xoebus git://github.com/xoebus/hub.git",
                    "git cherry-pick a319d88",
                    "cherry-pick xoebus@a319d88"
  end

  def test_am_untouched
    assert_forwarded "am some.patch"
  end

  def test_am_pull_request
    with_tmpdir('/tmp/') do
      assert_commands "curl -#LA 'hub #{Hub::Version}' https://github.com/defunkt/hub/pull/55.patch -o /tmp/55.patch",
                      "git am --signoff /tmp/55.patch -p2",
                      "am --signoff https://github.com/defunkt/hub/pull/55#comment_123 -p2"

      cmd = Hub("am https://github.com/defunkt/hub/pull/55/files").command
      assert_includes '/pull/55.patch', cmd
    end
  end

  def test_am_no_tmpdir
    with_tmpdir(nil) do
      cmd = Hub("am https://github.com/defunkt/hub/pull/55").command
      assert_includes '/tmp/55.patch', cmd
    end
  end

  def test_am_commit_url
    with_tmpdir('/tmp/') do
      url = 'https://github.com/davidbalbert/hub/commit/fdb9921'

      assert_commands "curl -#LA 'hub #{Hub::Version}' #{url}.patch -o /tmp/fdb9921.patch",
                      "git am --signoff /tmp/fdb9921.patch -p2",
                      "am --signoff #{url} -p2"
    end
  end

  def test_am_gist
    with_tmpdir('/tmp/') do
      url = 'https://gist.github.com/8da7fb575debd88c54cf'

      assert_commands "curl -#LA 'hub #{Hub::Version}' #{url}.txt -o /tmp/gist-8da7fb575debd88c54cf.txt",
                      "git am --signoff /tmp/gist-8da7fb575debd88c54cf.txt -p2",
                      "am --signoff #{url} -p2"
    end
  end

  def test_apply_untouched
    assert_forwarded "apply some.patch"
  end

  def test_apply_pull_request
    with_tmpdir('/tmp/') do
      assert_commands "curl -#LA 'hub #{Hub::Version}' https://github.com/defunkt/hub/pull/55.patch -o /tmp/55.patch",
                      "git apply /tmp/55.patch -p2",
                      "apply https://github.com/defunkt/hub/pull/55 -p2"

      cmd = Hub("apply https://github.com/defunkt/hub/pull/55/files").command
      assert_includes '/pull/55.patch', cmd
    end
  end

  def test_apply_commit_url
    with_tmpdir('/tmp/') do
      url = 'https://github.com/davidbalbert/hub/commit/fdb9921'

      assert_commands "curl -#LA 'hub #{Hub::Version}' #{url}.patch -o /tmp/fdb9921.patch",
                      "git apply /tmp/fdb9921.patch -p2",
                      "apply #{url} -p2"
    end
  end

  def test_apply_gist
    with_tmpdir('/tmp/') do
      url = 'https://gist.github.com/8da7fb575debd88c54cf'

      assert_commands "curl -#LA 'hub #{Hub::Version}' #{url}.txt -o /tmp/gist-8da7fb575debd88c54cf.txt",
                      "git apply /tmp/gist-8da7fb575debd88c54cf.txt -p2",
                      "apply #{url} -p2"
    end
  end

  def test_init
    stub_no_remotes
    stub_no_git_repo
    assert_commands "git init", "git remote add origin git@github.com:tpw/hub.git", "init -g"
  end

  def test_init_enterprise
    stub_no_remotes
    stub_no_git_repo
    stub_github_user('myfiname', 'git.my.org')
    with_host_env('git.my.org') do
      assert_commands "git init", "git remote add origin git@git.my.org:myfiname/hub.git", "init -g"
    end
  end

  def test_init_no_login
    out = hub("init -g") do
      stub_github_user(nil)
    end

    assert_equal "** No GitHub user set. See http://help.github.com/set-your-user-name-email-and-github-token/\n", out
  end

  def test_push_untouched
    assert_forwarded "push"
  end

  def test_push_two
    assert_commands "git push origin cool-feature", "git push staging cool-feature",
                    "push origin,staging cool-feature"
  end

  def test_push_current_branch
    stub_branch('refs/heads/cool-feature')
    assert_commands "git push origin cool-feature", "git push staging cool-feature",
                    "push origin,staging"
  end

  def test_push_more
    assert_commands "git push origin cool-feature",
                    "git push staging cool-feature",
                    "git push qa cool-feature",
                    "push origin,staging,qa cool-feature"
  end

  def test_create
    stub_no_remotes
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/json/repos/create").
      with(:body => { 'name' => 'hub' })

    expected = "remote add -f origin git@github.com:tpw/hub.git\n"
    expected << "created repository: tpw/hub\n"
    assert_equal expected, hub("create") { ENV['GIT'] = 'echo' }
  end

  def test_create_custom_name
    stub_no_remotes
    stub_nonexisting_fork('tpw', 'hubbub')
    stub_request(:post, "https://#{auth}github.com/api/v2/json/repos/create").
      with(:body => { 'name' => 'hubbub' })

    expected = "remote add -f origin git@github.com:tpw/hubbub.git\n"
    expected << "created repository: tpw/hubbub\n"
    assert_equal expected, hub("create hubbub") { ENV['GIT'] = 'echo' }
  end

  def test_create_in_organization
    stub_no_remotes
    stub_nonexisting_fork('acme', 'hubbub')
    stub_request(:post, "https://#{auth}github.com/api/v2/json/repos/create").
      with(:body => { 'name' => 'acme/hubbub' })

    expected = "remote add -f origin git@github.com:acme/hubbub.git\n"
    expected << "created repository: acme/hubbub\n"
    assert_equal expected, hub("create acme/hubbub") { ENV['GIT'] = 'echo' }
  end

  def test_create_no_openssl
    stub_no_remotes
    # stub_nonexisting_fork('tpw')
    stub_request(:get, "http://#{auth}github.com/api/v2/yaml/repos/show/tpw/hub").
      to_return(:status => 404)

    stub_request(:post, "http://#{auth}github.com/api/v2/json/repos/create").
      with(:body => { 'name' => 'hub' })

    expected = "remote add -f origin git@github.com:tpw/hub.git\n"
    expected << "created repository: tpw/hub\n"

    assert_equal expected, hub("create") {
      ENV['GIT'] = 'echo'
      require 'net/https'
      Object.send :remove_const, :OpenSSL
    }
  end

  def test_create_failed
    stub_no_remotes
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/json/repos/create").
      to_return(:status => [401, "Your token is fail"])

    expected = "Error creating repository: Your token is fail (HTTP 401)\n"
    expected << "Check your token configuration (`git config github.token`)\n"
    assert_equal expected, hub("create") { ENV['GIT'] = 'echo' }
  end

  def test_create_with_env_authentication
    stub_no_remotes
    old_user  = ENV['GITHUB_USER']
    old_token = ENV['GITHUB_TOKEN']
    ENV['GITHUB_USER']  = 'mojombo'
    ENV['GITHUB_TOKEN'] = '123abc'

    # stub_nonexisting_fork('mojombo')
    stub_request(:get, "https://#{auth('mojombo', '123abc')}github.com/api/v2/yaml/repos/show/mojombo/hub").
      to_return(:status => 404)

    stub_request(:post, "https://#{auth('mojombo', '123abc')}github.com/api/v2/json/repos/create").
      with(:body => { 'name' => 'hub' })

    expected = "remote add -f origin git@github.com:mojombo/hub.git\n"
    expected << "created repository: mojombo/hub\n"
    assert_equal expected, hub("create") { ENV['GIT'] = 'echo' }

  ensure
    ENV['GITHUB_USER']  = old_user
    ENV['GITHUB_TOKEN'] = old_token
  end

  def test_create_private_repository
    stub_no_remotes
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/json/repos/create").
      with(:body => { 'name' => 'hub', 'public' => '0' })

    expected = "remote add -f origin git@github.com:tpw/hub.git\n"
    expected << "created repository: tpw/hub\n"
    assert_equal expected, hub("create -p") { ENV['GIT'] = 'echo' }
  end

  def test_create_private_repository_fails
    stub_no_remotes
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/json/repos/create").
      to_return(:status => [422, "Unprocessable Entity"],
                :headers => {"Content-type" => "application/json"},
                :body => %({"error":"repository creation failed: You are over your quota."}))

    expected = "Error creating repository: Unprocessable Entity (HTTP 422)\n"
    expected << "repository creation failed: You are over your quota.\n"
    assert_equal expected, hub("create -p") { ENV['GIT'] = 'echo' }
  end

  def test_create_with_description_and_homepage
    stub_no_remotes
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/json/repos/create").with(:body => {
      'name' => 'hub', 'description' => 'toyproject', 'homepage' => 'http://example.com'
    })

    expected = "remote add -f origin git@github.com:tpw/hub.git\n"
    expected << "created repository: tpw/hub\n"
    assert_equal expected, hub("create -d toyproject -h http://example.com") { ENV['GIT'] = 'echo' }
  end

  def test_create_with_invalid_arguments
    assert_equal "invalid argument: -a\n",   hub("create -a blah")   { ENV['GIT'] = 'echo' }
    assert_equal "invalid argument: bleh\n", hub("create blah bleh") { ENV['GIT'] = 'echo' }
  end

  def test_create_with_existing_repository
    stub_no_remotes
    stub_existing_fork('tpw')

    expected = "tpw/hub already exists on github.com\n"
    expected << "remote add -f origin git@github.com:tpw/hub.git\n"
    expected << "set remote origin: tpw/hub\n"
    assert_equal expected, hub("create") { ENV['GIT'] = 'echo' }
  end

  def test_create_https_protocol
    stub_no_remotes
    stub_existing_fork('tpw')
    stub_https_is_preferred

    expected = "tpw/hub already exists on github.com\n"
    expected << "remote add -f origin https://github.com/tpw/hub.git\n"
    expected << "set remote origin: tpw/hub\n"
    assert_equal expected, hub("create") { ENV['GIT'] = 'echo' }
  end

  def test_create_no_user
    stub_no_remotes
    out = hub("create") do
      stub_github_token(nil)
    end
    assert_equal "** No GitHub token set. See http://help.github.com/set-your-user-name-email-and-github-token/\n", out
  end

  def test_create_outside_git_repo
    stub_no_git_repo
    assert_equal "'create' must be run from inside a git repository\n", hub("create")
  end

  def test_create_origin_already_exists
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/json/repos/create").
      with(:body => { 'name' => 'hub' })

    expected = "remote -v\ncreated repository: tpw/hub\n"
    assert_equal expected, hub("create") { ENV['GIT'] = 'echo' }
  end

  def test_fork
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/yaml/repos/fork/defunkt/hub").
      with { |req| req.headers['Content-Length'] == 0 }

    expected = "remote add -f tpw git@github.com:tpw/hub.git\n"
    expected << "new remote: tpw\n"
    assert_output expected, "fork"
  end

  def test_fork_https_protocol
    stub_https_is_preferred
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/yaml/repos/fork/defunkt/hub")

    expected = "remote add -f tpw https://github.com/tpw/hub.git\n"
    expected << "new remote: tpw\n"
    assert_equal expected, hub("fork") { ENV['GIT'] = 'echo' }
  end

  def test_fork_not_in_repo
    stub_no_git_repo
    expected = "fatal: Not a git repository\n"
    assert_output expected, "fork"
  end

  def test_fork_enterprise
    stub_hub_host('git.my.org')
    stub_repo_url('git@git.my.org:defunkt/hub.git')
    stub_github_user('myfiname', 'git.my.org')
    stub_github_token('789xyz', 'git.my.org')

    stub_request(:get, "https://#{auth('myfiname', '789xyz')}git.my.org/api/v2/yaml/repos/show/myfiname/hub").
      to_return(:status => 404)
    stub_request(:post, "https://#{auth('myfiname', '789xyz')}git.my.org/api/v2/yaml/repos/fork/defunkt/hub")

    expected = "remote add -f myfiname git@git.my.org:myfiname/hub.git\n"
    expected << "new remote: myfiname\n"
    assert_output expected, "fork"
  end

  def test_fork_failed
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/yaml/repos/fork/defunkt/hub").
      to_return(:status => [500, "Your fork is fail"])

    expected = "Error creating fork: Your fork is fail (HTTP 500)\n"
    assert_equal expected, hub("fork") { ENV['GIT'] = 'echo' }
  end

  def test_fork_no_remote
    stub_nonexisting_fork('tpw')
    stub_request(:post, "https://#{auth}github.com/api/v2/yaml/repos/fork/defunkt/hub")

    assert_equal "", hub("fork --no-remote") { ENV['GIT'] = 'echo' }
  end

  def test_fork_already_exists
    stub_existing_fork('tpw')

    expected = "Error creating fork: tpw/hub already exists on github.com\n"
    assert_equal expected, hub("fork") { ENV['GIT'] = 'echo' }
  end

  def test_pullrequest
    expected = "Aborted: head branch is the same as base (\"master\")\n" <<
      "(use `-h <branch>` to specify an explicit pull request head)\n"
    assert_output expected, "pull-request hereyougo"
  end

  def test_pullrequest_with_unpushed_commits
    stub_tracking('master', 'mislav', 'master')
    stub_command_output "rev-list --cherry-pick --right-only --no-merges mislav/master...", "+abcd1234\n+bcde2345"

    expected = "Aborted: 2 commits are not yet pushed to mislav/master\n" <<
      "(use `-f` to force submit a pull request anyway)\n"
    assert_output expected, "pull-request hereyougo"
  end

  def test_pullrequest_from_branch
    stub_branch('refs/heads/feature')
    stub_tracking_nothing('feature')

    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub").
      with(:body => { 'pull' => {'base' => "master", 'head' => "tpw:feature", 'title' => "hereyougo"} }) { |req|
        req.headers['Content-Length'] == 76
      }.to_return(:body => mock_pullreq_response(1))

    expected = "https://github.com/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -f"
  end

  def test_pullrequest_from_tracking_branch
    stub_branch('refs/heads/feature')
    stub_tracking('feature', 'mislav', 'yay-feature')

    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub").
      with(:body => { 'pull' => {'base' => "master", 'head' => "mislav:yay-feature", 'title' => "hereyougo"} }).
      to_return(:body => mock_pullreq_response(1))

    expected = "https://github.com/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -f"
  end

  def test_pullrequest_from_branch_tracking_local
    stub_branch('refs/heads/feature')
    stub_tracking('feature', 'refs/heads/master')

    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub").
      with(:body => { 'pull' => {'base' => "master", 'head' => "tpw:feature", 'title' => "hereyougo"} }).
      to_return(:body => mock_pullreq_response(1))

    expected = "https://github.com/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -f"
  end

  def test_pullrequest_invalid_remote
    stub_repo_url('gh:singingwolfboy/sekrit.git')
    stub_branch('refs/heads/feature')
    stub_tracking('feature', 'origin', 'feature')

    expected = "Aborted: the origin remote doesn't point to a GitHub repository.\n"
    assert_output expected, "pull-request hereyougo"
  end

  def test_pullrequest_enterprise_no_tracking
    stub_hub_host('git.my.org')
    stub_repo_url('git@git.my.org:defunkt/hub.git')
    stub_github_user('myfiname', 'git.my.org')
    stub_github_token('789xyz', 'git.my.org')
    stub_branch('refs/heads/feature')
    stub_tracking_nothing('feature')
    stub_command_output "rev-list --cherry-pick --right-only --no-merges origin/feature...", nil

    stub_request(:post, "https://#{auth('myfiname', '789xyz')}git.my.org/api/v2/json/pulls/defunkt/hub").
      with(:body => { 'pull' => {'base' => "master", 'head' => "myfiname:feature", 'title' => "hereyougo"} }).
      to_return(:body => mock_pullreq_response(1, 'defunkt/hub', 'git.my.org'))

    expected = "https://git.my.org/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -f"
  end

  def test_pullrequest_explicit_head
    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub").
      with(:body => { 'pull' => {'base' => "master", 'head' => "tpw:yay-feature", 'title' => "hereyougo"} }).
      to_return(:body => mock_pullreq_response(1))

    expected = "https://github.com/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -h yay-feature -f"
  end

  def test_pullrequest_explicit_head_with_owner
    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub").
      with(:body => { 'pull' => {'base' => "master", 'head' => "mojombo:feature", 'title' => "hereyougo"} }).
      to_return(:body => mock_pullreq_response(1))

    expected = "https://github.com/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -h mojombo:feature -f"
  end

  def test_pullrequest_explicit_base
    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub").
      with(:body => { 'pull' => {'base' => "feature", 'head' => "defunkt:master", 'title' => "hereyougo"} }).
      to_return(:body => mock_pullreq_response(1))

    expected = "https://github.com/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -b feature -f"
  end

  def test_pullrequest_explicit_base_with_owner
    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/mojombo/hub").
      with(:body => { 'pull' => {'base' => "feature", 'head' => "defunkt:master", 'title' => "hereyougo"} }).
      to_return(:body => mock_pullreq_response(1))

    expected = "https://github.com/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -b mojombo:feature -f"
  end

  def test_pullrequest_explicit_base_with_repo
    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/mojombo/hubbub").
      with(:body => { 'pull' => {'base' => "feature", 'head' => "defunkt:master", 'title' => "hereyougo"} }).
      to_return(:body => mock_pullreq_response(1))

    expected = "https://github.com/defunkt/hub/pull/1\n"
    assert_output expected, "pull-request hereyougo -b mojombo/hubbub:feature -f"
  end

  def test_pullrequest_existing_issue
    stub_branch('refs/heads/myfix')
    stub_tracking('myfix', 'mislav', 'awesomefix')
    stub_command_output "rev-list --cherry-pick --right-only --no-merges mislav/awesomefix...", nil

    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub").
      with(:body => { 'pull' => {'base' => "master", 'head' => "mislav:awesomefix", 'issue' => '92'} }).
      to_return(:body => mock_pullreq_response(92))

    expected = "https://github.com/defunkt/hub/pull/92\n"
    assert_output expected, "pull-request -i 92"
  end

  def test_pullrequest_existing_issue_url
    stub_branch('refs/heads/myfix')
    stub_tracking('myfix', 'mislav', 'awesomefix')
    stub_command_output "rev-list --cherry-pick --right-only --no-merges mislav/awesomefix...", nil

    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/mojombo/hub").
      with(:body => { 'pull' => {'base' => "master", 'head' => "mislav:awesomefix", 'issue' => '92'} }).
      to_return(:body => mock_pullreq_response(92, 'mojombo/hub'))

    expected = "https://github.com/mojombo/hub/pull/92\n"
    assert_output expected, "pull-request https://github.com/mojombo/hub/issues/92#comment_4"
  end

  def test_pullrequest_fails
    stub_request(:post, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub").
      to_return(:status => [422, "Unprocessable Entity"],
                :headers => {"Content-type" => "application/json"},
                :body => %({"error":["oh no!", "it failed."]}))

    expected = "Error creating pull request: Unprocessable Entity (HTTP 422)\n"
    expected << "oh no!\nit failed.\n"
    assert_output expected, "pull-request hereyougo -b feature -f"
  end

  def test_checkout_no_changes
    assert_forwarded "checkout master"
  end

  def test_checkout_pullrequest
    stub_request(:get, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub/73").
      to_return(:body => mock_pull_response('blueyed:feature'))

    assert_commands 'git remote add -f -t feature blueyed git://github.com/blueyed/hub.git',
      'git checkout -f --track -B blueyed-feature blueyed/feature -q',
      "checkout -f https://github.com/defunkt/hub/pull/73/files -q"
  end

  def test_checkout_private_pullrequest
    stub_request(:get, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub/73").
      to_return(:body => mock_pull_response('blueyed:feature', :private))

    assert_commands 'git remote add -f -t feature blueyed git@github.com:blueyed/hub.git',
      'git checkout --track -B blueyed-feature blueyed/feature',
      "checkout https://github.com/defunkt/hub/pull/73/files"
  end

  def test_checkout_pullrequest_custom_branch
    stub_request(:get, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub/73").
      to_return(:body => mock_pull_response('blueyed:feature'))

    assert_commands 'git remote add -f -t feature blueyed git://github.com/blueyed/hub.git',
      'git checkout --track -B review blueyed/feature',
      "checkout https://github.com/defunkt/hub/pull/73/files review"
  end

  def test_checkout_pullrequest_existing_remote
    stub_command_output 'remote', "origin\nblueyed"

    stub_request(:get, "https://#{auth}github.com/api/v2/json/pulls/defunkt/hub/73").
      to_return(:body => mock_pull_response('blueyed:feature'))

    assert_commands 'git remote set-branches --add blueyed feature',
      'git fetch blueyed +refs/heads/feature:refs/remotes/blueyed/feature',
      'git checkout --track -B blueyed-feature blueyed/feature',
      "checkout https://github.com/defunkt/hub/pull/73/files"
  end

  def test_version
    out = hub('--version')
    assert_includes "git version 1.7.0.4", out
    assert_includes "hub version #{Hub::Version}", out
  end

  def test_exec_path
    out = hub('--exec-path')
    assert_equal "/usr/lib/git-core\n", out
  end

  def test_exec_path_arg
    out = hub('--exec-path=/home/wombat/share/my-l33t-git-core')
    assert_equal improved_help_text, out
  end

  def test_html_path
    out = hub('--html-path')
    assert_equal "/usr/share/doc/git-doc\n", out
  end

  def test_help
    assert_equal improved_help_text, hub("help")
  end

  def test_help_by_default
    assert_equal improved_help_text, hub("")
  end

  def test_help_with_pager
    assert_equal improved_help_text, hub("-p")
  end

  def test_help_hub
    help_manpage = hub("help hub")
    assert_includes "git + hub = github", help_manpage
    assert_includes <<-config, help_manpage
Use git-config(1) to display the currently configured GitHub username:
config
  end

  def test_help_flag_on_command
    help_manpage = hub("browse --help")
    assert_includes "git + hub = github", help_manpage
    assert_includes "git browse", help_manpage
  end

  def test_help_short_flag_on_command
    usage_help = hub("create -h")
    expected = "Usage: git create [NAME] [-p] [-d DESCRIPTION] [-h HOMEPAGE]\n"
    assert_equal expected, usage_help

    usage_help = hub("pull-request -h")
    expected = "Usage: git pull-request [-f] [TITLE|-i ISSUE] [-b BASE] [-h HEAD]\n"
    assert_equal expected, usage_help
  end

  def test_help_hub_no_groff
    stub_available_commands()
    assert_equal "** Can't find groff(1)\n", hub("help hub")
  end

  def test_hub_standalone
    help_standalone = hub("hub standalone")
    assert_equal Hub::Standalone.build, help_standalone
  end

  def test_hub_compare
    assert_command "compare refactor",
      "open https://github.com/defunkt/hub/compare/refactor"
  end

  def test_hub_compare_nothing
    expected = "Usage: hub compare [USER] [<START>...]<END>\n"
    assert_equal expected, hub("compare")
  end

  def test_hub_compare_tracking_nothing
    stub_tracking_nothing
    expected = "Usage: hub compare [USER] [<START>...]<END>\n"
    assert_equal expected, hub("compare")
  end

  def test_hub_compare_tracking_branch
    stub_branch('refs/heads/feature')
    stub_tracking('feature', 'mislav', 'experimental')

    assert_command "compare",
      "open https://github.com/mislav/hub/compare/experimental"
  end

  def test_hub_compare_range
    assert_command "compare 1.0...fix",
      "open https://github.com/defunkt/hub/compare/1.0...fix"
  end

  def test_hub_compare_range_fixes_two_dots_for_tags
    assert_command "compare 1.0..fix",
      "open https://github.com/defunkt/hub/compare/1.0...fix"
  end

  def test_hub_compare_range_fixes_two_dots_for_shas
    assert_command "compare 1234abc..3456cde",
      "open https://github.com/defunkt/hub/compare/1234abc...3456cde"
  end

  def test_hub_compare_range_ignores_two_dots_for_complex_ranges
    assert_command "compare @{a..b}..@{c..d}",
      "open https://github.com/defunkt/hub/compare/@{a..b}..@{c..d}"
  end

  def test_hub_compare_on_wiki
    stub_repo_url 'git://github.com/defunkt/hub.wiki.git'
    assert_command "compare 1.0...fix",
      "open https://github.com/defunkt/hub/wiki/_compare/1.0...fix"
  end

  def test_hub_compare_fork
    assert_command "compare myfork feature",
      "open https://github.com/myfork/hub/compare/feature"
  end

  def test_hub_compare_url
    assert_command "compare -u 1.0...1.1",
      "echo https://github.com/defunkt/hub/compare/1.0...1.1"
  end

  def test_hub_browse
    assert_command "browse mojombo/bert", "open https://github.com/mojombo/bert"
  end

  def test_hub_browse_commit
    assert_command "browse mojombo/bert commit/5d5582", "open https://github.com/mojombo/bert/commit/5d5582"
  end

  def test_hub_browse_tracking_nothing
    stub_tracking_nothing
    assert_command "browse mojombo/bert", "open https://github.com/mojombo/bert"
  end

  def test_hub_browse_url
    assert_command "browse -u mojombo/bert", "echo https://github.com/mojombo/bert"
  end

  def test_hub_browse_self
    assert_command "browse resque", "open https://github.com/tpw/resque"
  end

  def test_hub_browse_subpage
    assert_command "browse resque commits",
      "open https://github.com/tpw/resque/commits/master"
    assert_command "browse resque issues",
      "open https://github.com/tpw/resque/issues"
    assert_command "browse resque wiki",
      "open https://github.com/tpw/resque/wiki"
  end

  def test_hub_browse_on_branch
    stub_branch('refs/heads/feature')
    stub_tracking('feature', 'mislav', 'experimental')

    assert_command "browse resque", "open https://github.com/tpw/resque"
    assert_command "browse resque commits",
      "open https://github.com/tpw/resque/commits/master"

    assert_command "browse",
      "open https://github.com/mislav/hub/tree/experimental"
    assert_command "browse -- tree",
      "open https://github.com/mislav/hub/tree/experimental"
    assert_command "browse -- commits",
      "open https://github.com/mislav/hub/commits/experimental"
  end

  def test_hub_browse_on_complex_branch
    stub_branch('refs/heads/feature/foo')
    stub_tracking('feature/foo', 'mislav', 'feature/bar')

    assert_command 'browse',
      'open https://github.com/mislav/hub/tree/feature/bar'
  end

  def test_hub_browse_no_branch
    stub_branch(nil)
    assert_command 'browse', 'open https://github.com/defunkt/hub'
  end

  def test_hub_browse_current
    assert_command "browse", "open https://github.com/defunkt/hub"
    assert_command "browse --", "open https://github.com/defunkt/hub"
  end

  def test_hub_browse_current_https_uri
    stub_repo_url "https://github.com/defunkt/hub"
    assert_command "browse", "open https://github.com/defunkt/hub"
  end

  def test_hub_browse_commit_from_current
    assert_command "browse -- commit/6616e4", "open https://github.com/defunkt/hub/commit/6616e4"
  end

  def test_hub_browse_no_tracking
    stub_tracking_nothing
    assert_command "browse", "open https://github.com/defunkt/hub"
  end

  def test_hub_browse_no_tracking_on_branch
    stub_branch('refs/heads/feature')
    stub_tracking_nothing('feature')
    assert_command "browse", "open https://github.com/defunkt/hub"
  end

  def test_hub_browse_current_wiki
    stub_repo_url 'git://github.com/defunkt/hub.wiki.git'

    assert_command "browse", "open https://github.com/defunkt/hub/wiki"
    assert_command "browse -- wiki", "open https://github.com/defunkt/hub/wiki"
    assert_command "browse -- commits", "open https://github.com/defunkt/hub/wiki/_history"
    assert_command "browse -- pages", "open https://github.com/defunkt/hub/wiki/_pages"
  end

  def test_hub_browse_current_subpage
    assert_command "browse -- network",
      "open https://github.com/defunkt/hub/network"
    assert_command "browse -- anything/everything",
      "open https://github.com/defunkt/hub/anything/everything"
  end

  def test_hub_browse_deprecated_private
    with_browser_env('echo') do
      assert_includes "Warning: the `-p` flag has no effect anymore\n", hub("browse -p defunkt/hub")
    end
  end

  def test_hub_browse_no_repo
    stub_repo_url(nil)
    assert_equal "Usage: hub browse [<USER>/]<REPOSITORY>\n", hub("browse")
  end

  def test_hub_browse_ssh_alias
    with_ssh_config do
      stub_repo_url "gh:singingwolfboy/sekrit.git"
      assert_command "browse", "open https://github.com/singingwolfboy/sekrit"
    end
  end

  def test_custom_browser
    with_browser_env("custom") do
      assert_browser("custom")
    end
  end

  def test_linux_browser
    stub_available_commands "open", "xdg-open", "cygstart"
    with_browser_env(nil) do
      with_host_os("i686-linux") do
        assert_browser("xdg-open")
      end
    end
  end

  def test_cygwin_browser
    stub_available_commands "open", "cygstart"
    with_browser_env(nil) do
      with_host_os("i686-linux") do
        assert_browser("cygstart")
      end
    end
  end

  def test_no_browser
    stub_available_commands()
    expected = "Please set $BROWSER to a web launcher to use this command.\n"
    with_browser_env(nil) do
      with_host_os("i686-linux") do
        assert_equal expected, hub("browse")
      end
    end
  end

  def test_context_method_doesnt_hijack_git_command
    assert_forwarded 'remotes'
  end

  def test_not_choking_on_ruby_methods
    assert_forwarded 'id'
    assert_forwarded 'name'
  end

  def test_multiple_remote_urls
    stub_repo_url("git://example.com/other.git\ngit://github.com/my/repo.git")
    assert_command "browse", "open https://github.com/my/repo"
  end

  def test_global_flags_preserved
    cmd = '--no-pager --bare -c core.awesome=true -c name=value --git-dir=/srv/www perform'
    assert_command cmd, 'git --bare -c core.awesome=true -c name=value --git-dir=/srv/www --no-pager perform'
    assert_equal %w[git --bare -c core.awesome=true -c name=value --git-dir=/srv/www], git_reader.executable
  end

  private

    def stub_github_user(name, host = '')
      host = %(."#{host}") unless host.empty?
      stub_config_value "github#{host}.user", name
    end

    def stub_github_token(token, host = '')
      host = %(."#{host}") unless host.empty?
      stub_config_value "github#{host}.token", token
    end

    def stub_repo_url(value, remote_name = 'origin')
      stub_config_value "remote.#{remote_name}.url", value, '--get-all'
    end

    def stub_branch(value)
      stub_command_output 'symbolic-ref -q HEAD', value
    end

    def stub_tracking(from, upstream, remote_branch = nil)
      stub_command_output "rev-parse --symbolic-full-name #{from}@{upstream}",
        remote_branch ? "refs/remotes/#{upstream}/#{remote_branch}" : upstream
    end

    def stub_tracking_nothing(from = 'master')
      stub_tracking(from, nil)
    end

    def stub_remotes_group(name, value)
      stub_config_value "remotes.#{name}", value
    end

    def stub_no_remotes
      stub_command_output 'remote', nil
    end

    def stub_no_git_repo
      stub_command_output 'rev-parse -q --git-dir', nil
    end

    def stub_alias(name, value)
      stub_config_value "alias.#{name}", value
    end

    def stub_existing_fork(user, repo = 'hub')
      stub_fork(user, repo, 200)
    end

    def stub_nonexisting_fork(user, repo = 'hub')
      stub_fork(user, repo, 404)
    end

    def stub_fork(user, repo, status)
      stub_request(:get, "https://#{auth}github.com/api/v2/yaml/repos/show/#{user}/#{repo}").
        to_return(:status => status)
    end

    def stub_available_commands(*names)
      COMMANDS.replace names
    end

    def stub_https_is_preferred
      stub_config_value 'hub.protocol', 'https'
    end

    def stub_hub_host(names)
      stub_config_value "hub.host", Array(names).join("\n"), '--get-all'
    end

    def with_browser_env(value)
      browser, ENV['BROWSER'] = ENV['BROWSER'], value
      yield
    ensure
      ENV['BROWSER'] = browser
    end

    def with_tmpdir(value)
      dir, ENV['TMPDIR'] = ENV['TMPDIR'], value
      yield
    ensure
      ENV['TMPDIR'] = dir
    end

    def with_host_env(value)
      host, ENV['GITHUB_HOST'] = ENV['GITHUB_HOST'], value
      yield
    ensure
      ENV['GITHUB_HOST'] = host
    end

    def assert_browser(browser)
      assert_command "browse", "#{browser} https://github.com/defunkt/hub"
    end

    def with_host_os(value)
      host_os = RbConfig::CONFIG['host_os']
      RbConfig::CONFIG['host_os'] = value
      begin
        yield
      ensure
        RbConfig::CONFIG['host_os'] = host_os
      end
    end

    def auth(user = git_config('github.user'), password = git_config('github.token'))
      "#{user}%2Ftoken:#{password}@"
    end

    def mock_pullreq_response(id, name_with_owner = 'defunkt/hub', host = 'github.com')
      %({"pull": { "html_url": "https://#{host}/#{name_with_owner}/pull/#{id}" }})
    end

    def mock_pull_response(label, priv = false)
      %({"pull": { "head": { "label": "#{label}", "repository": {"private":#{!!priv}} }}})
    end

    def improved_help_text
      Hub::Commands.send :improved_help_text
    end

    def with_ssh_config
      config_file = File.expand_path '../ssh_config', __FILE__
      Hub::Context::SshConfig::CONFIG_FILES.replace [config_file]
      yield
    end

end
