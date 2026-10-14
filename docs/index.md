---
layout: home
title: MXC for Ruby
description: Run untrusted commands from Ruby in an OS sandbox that controls what they read, write, and reach.
permalink: /
hero:
  name: MXC for Ruby
  text: Run untrusted commands in an OS sandbox
  tagline: Give code your application did not write only the files, hosts, and time you choose. One gem, built on Microsoft's MXC, on Linux, macOS, and Windows.
  code_panel:
    - title: Define a sandbox
      file: app/sandboxes/skill_sandbox.rb
      link: /policies/
      code: |
        ```ruby
        class SkillSandbox < MXC::Sandbox
          readable "app/skills"
          writable "tmp/skills"
          denied "app/skills/secrets"
          directory "app/skills"
          network allow: ["pypi.org"]
          timeout 30
        end
        ```
    - title: Run a command
      file: app/jobs/build_skill_job.rb
      link: /running-commands/
      code: |
        ```ruby
        sandbox = SkillSandbox.new
        result = sandbox.run("python3 build.py")

        result.success? # => true
        result.stdout   # => "Built report.pdf\n"
        ```
    - title: Allowed hosts
      file: app/jobs/install_job.rb
      link: /policies/#allowed-hosts
      code: |
        ```ruby
        sandbox = SkillSandbox.new
        result = sandbox.run("pip index versions flask")

        result.blocked # => ["telemetry.example.com:443"]
        ```
    - title: Streaming
      file: app/jobs/build_skill_job.rb
      link: /running-commands/#streaming
      code: |
        ```ruby
        sandbox = SkillSandbox.new

        sandbox.run("python3", "build.py") do |chunk|
          print chunk.content
        end
        ```
    - title: Interactive processes
      file: app/models/console.rb
      link: /running-commands/#interactive-processes
      code: |
        ```ruby
        process = SkillSandbox.new.spawn("python3 -i -q")
        process.write("print(6 * 7)\n")
        process.close_write

        process.each { |chunk| print chunk.content }
        process.wait.success? # => true
        ```
    - title: Check the host
      file: config/initializers/mxc.rb
      link: /checking-the-host/
      code: |
        ```ruby
        SkillSandbox.new.supported? # => false

        SkillSandbox.new.availability.remediation
        # => "Install slirp4netns, iptables ..."
        ```
  actions:
    - theme: brand
      text: Get Started
      link: /getting-started/
    - theme: alt
      text: Read the Overview
      link: /overview/
    - theme: alt
      text: View on GitHub
      link: https://github.com/crmne/mxc
features:
  - icon: 📂
    title: Only the files you grant
    details: List what the command may read and write, and deny paths inside them. Everything else on the machine stays out of reach.
    link: /policies/#filesystem
    link_text: Filesystem policies
  - icon: 🌐
    title: No network unless you say so
    details: Commands start offline. Turn the network on, or allow only the hosts you list, and see which requests were blocked.
    link: /policies/#network
    link_text: Network policies
  - icon: ⏱️
    title: Timeouts, streaming, and processes
    details: Stop runaway commands, stream output as it arrives, or spawn a process to write to, read from, and kill.
    link: /running-commands/
    link_text: Running commands
  - icon: 💻
    title: Linux, macOS, and Windows
    details: Bubblewrap, Seatbelt, and Windows process containers behind one API. Precompiled gems, no service to run.
    link: /overview/#how-it-works
    link_text: How it works
  - icon: 🩺
    title: Know before you rely on it
    details: Check whether the machine can sandbox at boot, with a remediation that says what to install when it cannot.
    link: /checking-the-host/
    link_text: Checking the host
  - icon: 🐳
    title: Ready for Docker and Kamal
    details: A minimal seccomp profile, a Bubblewrap wrapper, and a Kamal job role that let containers start sandboxes.
    link: /running-in-docker/
    link_text: Running in Docker
---
