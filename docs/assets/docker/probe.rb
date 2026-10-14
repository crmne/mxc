# frozen_string_literal: true

# Checks that MXC sandboxes work in this container and reports what the
# untrusted code inside a sandbox can reach. Prints one "name: result" line
# per check. Usage: ruby probe.rb [--quick]
$LOAD_PATH.unshift(ENV.fetch("MXC_LIB", "/app/lib"))
require "mxc"
require "tmpdir"

def check(name)
  puts "#{name}: #{yield}"
rescue MXC::Error => e
  puts "#{name}: #{e.class} #{e.message.lines.first&.strip}"
end

def describe(result)
  description = "exit=#{result.exit_code} out=#{result.stdout.strip.inspect}"
  description += " err=#{result.stderr.strip[0, 200].inspect}" unless result.stderr.strip.empty?
  description
end

def sandboxed(command, **options)
  describe(MXC.run(command, timeout: 20, **options))
end

check("echo") { sandboxed("echo hi") }

Dir.mktmpdir("mxc-confine", ENV.fetch("PROBE_TMP", Dir.tmpdir)) do |base|
  readable = File.join(base, "readable")
  writable = File.join(base, "writable")
  [readable, writable].each { |path| Dir.mkdir(path) }
  File.write(File.join(readable, "in.txt"), "hello")
  check("fs_policy") do
    output = File.join(writable, "out.txt")
    sandboxed(
      "python3 -c \"import pathlib; d=pathlib.Path('#{readable}/in.txt').read_text(); " \
      "pathlib.Path('#{output}').write_text(d.upper()); print('wrote')\" && " \
      "(echo x > #{readable}/hack 2>/dev/null && echo RO-WRITE-OK || echo ro-write-blocked)",
      readable:, writable:
    ) + " rw_file=#{File.exist?(output) ? File.read(output) : 'missing'}"
  end
end
check("python subprocess+multiprocessing") do
  sandboxed("python3 -c \"import subprocess, multiprocessing as m; " \
            "print(subprocess.run(['echo','sub'],capture_output=True,text=True).stdout.strip(), " \
            "m.Pool(2).map(abs,[-1,-2]))\"")
end
exit if ARGV.include?("--quick")

check("inner max_user_namespaces") { sandboxed("cat /proc/sys/user/max_user_namespaces") }
check("inner unshare -U") { sandboxed("unshare -U true && echo USERNS-CREATED") }
check("inner unshare -U, network true") do
  sandboxed("curl -sS -o /dev/null -w '%{http_code} ' https://example.com; unshare -U true && echo USERNS-CREATED",
            network: true)
end
check("inner unshare -Ur (map root)") { sandboxed("unshare -Ur id -u") }
check("inner nested bwrap") do
  sandboxed("bwrap --unshare-user --unshare-pid --ro-bind / / --proc /proc true && echo NESTED-BWRAP-OK")
end
check("inner processes visible") { sandboxed("ls /proc | grep -c '^[0-9]'") }
check("inner sees worker cmdline") do
  sandboxed("cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\\0' ' ' | grep -c '[d]ocker/probe'")
end
check("inner getpid matches /proc/self") do
  sandboxed("python3 -c \"import os; print(os.getpid() == int(os.readlink('/proc/self')))\"")
end
check("inner /proc/kcore") do
  sandboxed("ls -l /proc/kcore 2>&1; head -c1 /proc/kcore >/dev/null 2>&1 && echo READABLE || echo not-readable")
end
check("inner /proc/keys,/proc/timer_list") do
  sandboxed("for f in keys timer_list sched_debug; do head -c 40 /proc/$f >/dev/null 2>&1 && echo $f:readable " \
            "|| echo $f:no; done | tr '\\n' ' '")
end
check("inner /proc writable files") do
  sandboxed("for f in sys/kernel/core_pattern sys/kernel/ns_last_pid sysrq-trigger; do test -w /proc/$f " \
            "&& echo $f:WRITABLE || echo $f:no; done | tr '\\n' ' '")
end
check("inner /sys") { sandboxed("ls /sys 2>&1 | head -3 | tr '\\n' ' '") }
check("inner seccomp mode") do
  sandboxed("grep -E '^(Seccomp|Seccomp_filters|CapEff|NoNewPrivs):' /proc/self/status | tr '\\n' ' '")
end
check("allow-list reaches pypi.org") do
  sandboxed("curl -sS -o /dev/null -w '%{http_code}' https://pypi.org/simple/", network: { allow: ["pypi.org"] })
end
check("allow-list refuses example.com") do
  sandboxed("curl -sS -o /dev/null -w '%{http_code}' https://example.com", network: { allow: ["pypi.org"] })
end
