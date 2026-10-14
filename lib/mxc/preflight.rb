# frozen_string_literal: true

module MXC
  module Preflight # :nodoc:
    NETWORK_TOOLS = %w[slirp4netns iptables ip6tables iptables-restore ip6tables-restore nsenter unshare].freeze
    TUN = '/dev/net/tun'
    INSTALL = 'Install slirp4netns, iptables and util-linux ' \
              '(Debian/Ubuntu: apt-get install slirp4netns iptables util-linux; ' \
              'Fedora: dnf install slirp4netns iptables-nft util-linux; ' \
              'Arch: pacman -S slirp4netns iptables util-linux)'
    WINDOWS_ALLOW_LIST = 'Use network: false, or network: true for unrestricted access. On Windows, MXC confines ' \
                         'a sandbox to a proxy only by also accepting inbound connections to it'
    WINDOWS_DENIED = 'Leave the paths out of readable and writable instead, or run on a Windows build where ' \
                     'MXC.supports?(:filesystem_denied_paths) is true'
    MACOS_MEMORY = 'Leave memory out of the limits on macOS, which rejects memory rlimits. ' \
                   'Linux and Windows support it'
    PROCESS_LIMIT = 'Leave processes out of the limits. Only Windows can count the processes of one sandbox; ' \
                    'in a container, limit them with docker run --pids-limit'

    module_function

    def check!(network:, denied: [], resources: nil)
      error = problem(network:, denied:, resources:)
      raise error if error
    end

    def problem(network:, denied: [], resources: nil, path: ENV.fetch('PATH', ''), tun: TUN)
      resource_problem(resources) || host_problem(network, denied, path, tun)
    end

    def resource_problem(resources)
      return if resources.nil? || windows?

      if resources[:max_processes]
        UnsupportedError.new("Process limits are not supported on #{linux? ? 'Linux' : 'macOS'}",
                             code: :backend_unavailable, remediation: PROCESS_LIMIT)
      elsif resources[:memory_mb] && !linux?
        UnsupportedError.new('Memory limits are not supported on macOS',
                             code: :backend_unavailable, remediation: MACOS_MEMORY)
      end
    end

    def host_problem(network, denied, path, tun)
      return windows_problem(network, denied) if windows?
      return unless network && linux?

      missing = NETWORK_TOOLS.reject { |tool| executable?(tool, path) }
      if missing.any?
        return UnsupportedError.new("Network access from a sandbox needs #{missing.join(', ')} on PATH",
                                    code: :backend_unavailable, remediation: INSTALL)
      end
      return if tun_usable?(tun)

      UnsupportedError.new("Network access from a sandbox needs a usable #{tun}",
                           code: :backend_unavailable, remediation: tun_remediation)
    end

    def linux?
      RUBY_PLATFORM.include?('linux')
    end

    def windows?
      Gem.win_platform?
    end

    def windows_problem(network, denied)
      if network.is_a?(Hash)
        UnsupportedError.new('Host allow-lists are not supported on Windows',
                             code: :backend_unavailable, remediation: WINDOWS_ALLOW_LIST)
      elsif denied.any? && !denied_paths_enforced?
        UnsupportedError.new("MXC's AppContainer sandbox on this Windows build does not enforce denied paths",
                             code: :backend_unavailable, remediation: WINDOWS_DENIED)
      end
    end

    def denied_paths_enforced?
      MXC.backends.any? { |backend| backend.supports?(:filesystem_denied_paths) }
    end

    def executable?(tool, path)
      path.split(File::PATH_SEPARATOR).any? do |dir|
        file = File.join(dir, tool)
        File.file?(file) && File.executable?(file)
      end
    end

    def tun_usable?(tun)
      File.open(tun, File::RDWR) { true }
    rescue SystemCallError
      false
    end

    def tun_remediation
      if File.exist?('/.dockerenv') || File.exist?('/run/.containerenv')
        'Pass the TUN device to the container: docker run --device /dev/net/tun ' \
          '(Kamal: options: { device: /dev/net/tun } on the role)'
      else
        'Load the tun kernel module: sudo modprobe tun'
      end
    end
  end
end
