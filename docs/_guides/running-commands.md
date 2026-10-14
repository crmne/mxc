---
title: Running Commands
nav_order: 2
description: Run a command and read its result, stream output as it arrives, or drive an interactive process.
---

After reading this guide, you will know:

* How commands are interpreted.
* What a result contains.
* How to stream output while a command runs.
* How to write to a running process, wait for it, or stop it.

## Commands

`run` and `spawn` take a command the way `Kernel#system` and `Open3.capture3` do. One String runs through `sh -c` inside the sandbox, so pipes, redirects, and `&&` work:

```ruby
MXC.run("python3 build.py && ls dist | wc -l")
```

Two or more Strings are a program and its arguments. No shell interprets them, so each argument reaches the program unchanged. Use this form whenever part of the command comes from user input:

```ruby
MXC.run("python3", "convert.py", params[:filename])
```

Policy keywords follow the command:

```ruby
MXC.run("python3", "convert.py", params[:filename], readable: "app/skills", timeout: 30)
```

Arguments are Strings or Pathnames. Splat a list you built with `*`: passing an Array raises `ArgumentError`, and so does passing no command at all.

The command starts from a minimal environment (`PATH`, `TERM`, and little else). Add variables with [`env`]({% link _guides/policies.md %}#environment).

### Windows

On Windows, one String runs through `cmd.exe /d /s /c`, so `&`, `&&`, `|`, redirects, and `%VARIABLES%` work the way they do in a Command Prompt:

```ruby
MXC.run("python build.py && dir dist")
```

Quote a program's full path. `cmd.exe` looks up an unquoted path one folder at a time from the root of the drive, which the sandbox cannot read, and fails with "Access is denied":

```ruby
MXC.run('"C:\\Program Files\\Python313\\python.exe" build.py')
```

A program and its arguments start the program directly, without `cmd.exe`. Each argument is quoted so the program receives it unchanged:

```ruby
MXC.run("python", "convert.py", params[:filename])
```

Windows runs `.bat` and `.cmd` files through `cmd.exe`, which splits arguments again, so starting one with separate arguments raises `ArgumentError`. Run batch files with one String and quote anything that comes from users yourself.

Output uses Windows line endings (`"\r\n"`). Programs that need the Windows UI subsystem cannot start in the sandbox, because MXC blocks it: PowerShell, `tasklist`, and `whoami`, for example, exit with code `-1073741502` (`STATUS_DLL_INIT_FAILED`). Command-line tools such as Python, `curl.exe`, `findstr`, and the `cmd.exe` built-ins work.

## Results

`run` waits for the command to finish and returns an `MXC::Result`:

```ruby
result = MXC.run("python3 build.py", readable: "app/skills", timeout: 30)

result.success?   # => true when it exited with 0 before the timeout
result.exit_code  # => 0, or nil when it timed out
result.timed_out? # => false
result.stdout     # => "built 3 files\n"
result.stderr     # => ""
result.warnings   # => [] (MXC's notes about the sandbox)
result.blocked    # => [] (hosts the network allow-list refused)
result.backend    # => :bubblewrap
```

A command that fails is still a result: check `success?` and read `stderr`. `run` raises `MXC::Error` only when the sandbox itself cannot start, as described in [Checking the Host]({% link _guides/checking-the-host.md %}).

`stdout` and `stderr` use `Encoding.default_external`, like `Open3`. A command killed by a signal reports an exit code of `-1`. On Windows, `kill` and timeouts stop the command's whole process tree.

## Streaming

Pass a block to receive output as it arrives. Each `MXC::Chunk` knows which stream it came from:

```ruby
result = MXC.run("python3 train.py", timeout: 600) do |chunk|
  if chunk.stderr?
    logger.warn(chunk.content)
  else
    print chunk.content
  end
end
```

`run` still returns the complete `Result` once the command finishes. If the block raises, the command is stopped.

To stream to a Rails view, broadcast from the block:

```ruby
sandbox.run(command) do |chunk|
  Turbo::StreamsChannel.broadcast_append_to(job, target: "output", html: ERB::Util.h(chunk.content))
end
```

## Interactive processes

`spawn` starts a command and returns an `MXC::Process` without waiting:

```ruby
process = MXC.sandbox.with_timeout(60).spawn("python3 -i -q")
process.write("print(6 * 7)\n")
process.close_write

process.each { |chunk| print chunk.content }
result = process.wait
```

* `write` sends data to the command's standard input.
* `close_write` closes standard input, so the command reads end of file.
* `each` yields chunks until the command closes both output streams. Without a block it returns an Enumerator.
* `wait` closes standard input, waits for the command to finish, and returns its `Result`, including any output `each` already yielded.
* `kill` stops the command and everything it started.
* `pid` returns the operating system process id of the sandbox.

The process reads its output in the background from the moment it starts, so a chatty command never blocks on a full pipe, and its timeout applies even if nothing calls `each` or `wait`.

You can call `kill` from another thread while one is blocked in `each`:

```ruby
process = sandbox.spawn("python3 server.py")
Thread.new { sleep 10; process.kill }
process.each { |chunk| print chunk.content }
process.wait.success? # => false
```

## Timeouts

Set a timeout in seconds on the sandbox, per call, or for everything in `MXC.configure`. It accepts anything that responds to `to_f`, including `ActiveSupport::Duration`:

```ruby
MXC.run("python3 build.py", timeout: 2.minutes)
```

When the time runs out, MXC stops the command and everything it started, and the result reports `timed_out?`. Without a timeout, a command runs until it exits.

Prefer the sandbox's timeout over `Timeout.timeout`: the wait happens outside Ruby's interpreter lock, where `Timeout` cannot interrupt it.
{: .tip }
