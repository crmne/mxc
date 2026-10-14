# frozen_string_literal: true

require 'test_helper'
require 'socket'

module MXC
  class NetworkTest < Minitest::Test
    def setup
      super
      skip_unless_network
      skip "this host's Bubblewrap cannot confine egress to a proxy" unless MXC.supports?(:network_policy)
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      @thread = Thread.new { serve }
    end

    def teardown
      @server&.close
      @thread&.join(1)
      super
    end

    def curl(url) = "curl -sS -m 10 -o /dev/null -w '%{http_code}' #{url}"

    def test_allowed_hosts_are_reachable
      result = MXC.run(curl("http://127.0.0.1:#{@port}/"), network: { allow: ["127.0.0.1:#{@port}"] }, timeout: 30)

      assert_equal '200', result.stdout
      assert_empty result.blocked
    end

    def test_other_hosts_are_refused_and_reported
      result = MXC.run(curl("http://127.0.0.1:#{@port}/"), network: { allow: ['pypi.org'] }, timeout: 30)

      assert_equal '403', result.stdout
      assert_equal ["127.0.0.1:#{@port}"], result.blocked
    end

    def test_names_resolving_to_private_addresses_are_refused
      result = MXC.run(curl("http://localhost:#{@port}/"), network: { allow: ["localhost:#{@port}"] }, timeout: 30)

      assert_equal '403', result.stdout
    end

    def test_connections_that_bypass_the_proxy_fail
      result = MXC.run("curl -sS -m 5 --noproxy '*' http://10.0.2.2:#{@port}/",
                       network: { allow: ["127.0.0.1:#{@port}"] }, timeout: 30)

      refute_predicate result, :success?
    end

    def test_malformed_allow_lists_are_rejected
      assert_raises(ArgumentError) { MXC.run('true', network: { allow: ['10.0.0.0/8'] }) }
      assert_raises(ArgumentError) { MXC.run('true', network: { allow: ['foo.*.com'] }) }
    end

    def test_spawned_processes_report_blocked_hosts_on_wait
      process = MXC.spawn(curl("http://127.0.0.1:#{@port}/"), network: { allow: ['pypi.org'] }, timeout: 30)
      result = process.wait

      assert_equal '403', result.stdout
      assert_equal ["127.0.0.1:#{@port}"], result.blocked
    end

    private

    def serve
      loop do
        client = @server.accept
        client.readpartial(4096)
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end
end
