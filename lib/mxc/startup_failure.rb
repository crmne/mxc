# frozen_string_literal: true

module MXC
  module StartupFailure # :nodoc:
    DOCKER_GUIDE = 'https://crmne.github.io/mxc/running-in-docker/'
    NAMESPACES = Regexp.union(/No permissions to create a?\s*new namespace/i, /Creating new namespace failed/i,
                              /setting up uid map/i, /unshare.*Operation not permitted/i)
    PROC = /Can't mount proc|mount proc on/i
    HOST_PROBLEMS = {
      NAMESPACES => 'Unprivileged user namespaces are blocked. On a host, enable kernel.unprivileged_userns_clone=1 ' \
                    'and, on Ubuntu 23.10 and later, allow bwrap in AppArmor ' \
                    '(kernel.apparmor_restrict_unprivileged_userns). ' \
                    "In Docker, run with a seccomp profile that allows namespaces: #{DOCKER_GUIDE}",
      PROC => 'bwrap cannot mount a fresh /proc because the container masks /proc paths. ' \
              "In Docker, see #{DOCKER_GUIDE}"
    }.freeze
    CHDIR = /Can't chdir/i
    BWRAP_LINE = /^bwrap: .*$/

    module_function

    def detect(outcome)
      failure = outcome[:failure] or return
      reason = outcome[:stderr].to_s.scan(BWRAP_LINE).last
      return Error.new(failure, code: :backend_error) unless reason

      message = "Bubblewrap could not start the sandbox: #{reason}"
      hint = hint(reason)
      return UnsupportedError.new(message, code: :backend_unavailable, remediation: hint, operation: 'bwrap') if hint

      remediation = 'Make the directory readable or writable in the sandbox' if reason.match?(CHDIR)
      Error.new(message, code: :backend_error, remediation:, operation: 'bwrap')
    end

    def hint(message)
      HOST_PROBLEMS.find { |pattern, _| message.match?(pattern) }&.last
    end

    def check!(outcome)
      error = detect(outcome)
      raise error if error

      outcome
    end
  end
end
