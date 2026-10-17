use std::ffi::c_void;
use std::io::{Read, Write};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use magnus::{
    function, method, prelude::*, Error, RArray, RHash, RModule, RString, Ruby, Symbol,
};
use mxc_sdk::v1::{
    self,
    configs::{ProcessContainerConfig, SeatbeltConfig},
    Containment, ContainerRequest, ExecutionMetadata, FilesystemPolicy, MxcProcess,
    NetworkAction, NetworkEgressPolicy, NetworkPolicy, NetworkRuntimeConfig, ResourceLimit,
    StreamCloser, WaitResult,
};
use serde_json::{json, Map, Value};

mod proxy;

use proxy::{Allowlist, EgressProxy};

const MAX_POLL: Duration = Duration::from_millis(50);
/// How long a sandbox that failed may keep its output streams open before
/// they are closed. Nothing it started runs on, so they end at once.
const DRAIN: Duration = Duration::from_secs(1);

fn drain_until(drained: impl Fn() -> bool) {
    let deadline = Instant::now() + DRAIN;
    while !drained() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn without_gvl<F, R>(f: F) -> R
where
    F: FnOnce() -> R,
{
    struct Payload<F, R> {
        f: Option<F>,
        r: Option<std::thread::Result<R>>,
    }
    extern "C" fn call<F: FnOnce() -> R, R>(data: *mut c_void) -> *mut c_void {
        let payload = unsafe { &mut *(data as *mut Payload<F, R>) };
        let f = payload.f.take().unwrap();
        payload.r = Some(std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)));
        std::ptr::null_mut()
    }
    let mut payload = Payload { f: Some(f), r: None };
    unsafe {
        rb_sys::rb_thread_call_without_gvl(
            Some(call::<F, R>),
            &mut payload as *mut _ as *mut c_void,
            None,
            std::ptr::null_mut(),
        );
    }
    match payload.r.unwrap() {
        Ok(r) => r,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

fn native_module(ruby: &Ruby) -> Result<RModule, Error> {
    let mxc: RModule = ruby.class_object().const_get("MXC")?;
    mxc.const_get("Native")
}

fn mxc_error(ruby: &Ruby, e: v1::Error) -> Error {
    let build = || -> Result<magnus::Exception, Error> {
        let kw = ruby.hash_new();
        kw.aset(ruby.to_symbol("code"), ruby.to_symbol(e.code.as_str()))?;
        kw.aset(ruby.to_symbol("remediation"), e.remediation.clone())?;
        kw.aset(ruby.to_symbol("operation"), e.operation.clone())?;
        kw.aset(ruby.to_symbol("native_code"), e.native_code.clone())?;
        native_module(ruby)?.funcall("error", (e.message.clone(), magnus::KwArgs(kw)))
    };
    match build() {
        Ok(exc) => Error::from(exc),
        Err(err) => err,
    }
}

fn io_error(ruby: &Ruby, e: std::io::Error) -> Error {
    Error::new(ruby.exception_io_error(), e.to_string())
}

fn arg_error(ruby: &Ruby, message: String) -> Error {
    Error::new(ruby.exception_arg_error(), message)
}

fn opt<T: magnus::TryConvert>(ruby: &Ruby, h: RHash, key: &str) -> Result<Option<T>, Error> {
    h.lookup::<_, Option<T>>(ruby.to_symbol(key))
}

fn deny_all() -> NetworkEgressPolicy {
    NetworkEgressPolicy {
        default: Some(NetworkAction::Deny),
        ..Default::default()
    }
}

/// A request ready to start: the typed request, or, when it carries resource
/// limits, which MXC's typed V1 request cannot express yet, the same request
/// as `1.1.0-alpha` JSON.
enum Request {
    Typed(Box<ContainerRequest>),
    Json(String),
}

impl Request {
    fn spawn(self) -> Result<MxcProcess, v1::Error> {
        match self {
            Request::Typed(req) => v1::spawn(*req, Default::default()),
            Request::Json(json) => mxc_sdk::__ffi::spawn_container_json(&json, false),
        }
    }
}

fn resources(ruby: &Ruby, opts: RHash) -> Result<Option<Value>, Error> {
    let Some(limits) = opt::<RHash>(ruby, opts, "resources")? else {
        return Ok(None);
    };
    let mut resources = Map::new();
    if let Some(ms) = opt::<u64>(ruby, limits, "cpu_time_ms")? {
        resources.insert("cpuTimeMs".into(), ms.into());
    }
    if let Some(mb) = opt::<u64>(ruby, limits, "memory_mb")? {
        resources.insert("memoryMb".into(), mb.into());
    }
    if let Some(count) = opt::<u32>(ruby, limits, "max_processes")? {
        resources.insert("maxProcesses".into(), count.into());
    }
    if let Some(priority) = opt::<String>(ruby, limits, "priority")? {
        resources.insert("priority".into(), priority.into());
    }
    Ok(Some(Value::Object(resources)))
}

fn action(action: Option<NetworkAction>) -> &'static str {
    match action {
        Some(NetworkAction::Allow) => "allow",
        _ => "deny",
    }
}

// Mirrors the 1.0.0 document MXC's typed V1 request produces, plus `resources`.
fn request_json(ruby: &Ruby, req: &ContainerRequest, resources: Value) -> Result<String, Error> {
    let filesystem = req.filesystem.clone().unwrap_or_default();
    let mut process = json!({
        "commandLine": req.command,
        "timeout": req.timeout_ms.unwrap_or(0),
    });
    if let Some(cwd) = &req.working_directory {
        process["cwd"] = cwd.clone().into();
    }
    if let Some(environment) = &req.environment {
        let env: Vec<String> = environment
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect();
        process["env"] = env.into();
    }
    let mut document = json!({
        "version": "1.1.0-alpha",
        "containerId": mxc_sdk::mxc_common::id::mint_random_token(),
        "lifecycle": { "destroyOnExit": true, "preservePolicy": false },
        "process": process,
        "filesystem": {
            "readwritePaths": filesystem.readwrite_paths,
            "readonlyPaths": filesystem.readonly_paths,
            "deniedPaths": filesystem.denied_paths,
        },
        "resources": resources,
    });
    if let Some(network) = &req.network {
        let default = action(network.egress.as_ref().and_then(|egress| egress.default));
        document["network"] = json!({ "egress": { "default": default } });
        if let Some(proxy) = network
            .runtime_config
            .as_ref()
            .and_then(|runtime| runtime.network_proxy.clone())
        {
            document["runtimeConfig"] = json!({ "networkProxy": proxy });
        }
    }
    document["containment"] = match &req.containment {
        Containment::Process => "process".into(),
        Containment::Bubblewrap => "bubblewrap".into(),
        Containment::Seatbelt(_) => {
            document["seatbelt"] = json!({
                "guiAccess": false,
                "nestedPty": true,
                "keychainAccess": false,
                "extraMachLookups": [],
            });
            "seatbelt".into()
        }
        Containment::ProcessContainer(_) => {
            document["processContainer"] = json!({ "leastPrivilege": false, "capabilities": [] });
            "processcontainer".into()
        }
        _ => {
            return Err(arg_error(
                ruby,
                "unsupported backend for resource limits".into(),
            ))
        }
    };
    Ok(document.to_string())
}

fn prepare(
    ruby: &Ruby,
    command: String,
    opts: RHash,
) -> Result<(Request, Option<EgressProxy>), Error> {
    let (req, egress_proxy) = build_request(ruby, command, opts)?;
    let request = match resources(ruby, opts)? {
        Some(resources) => Request::Json(request_json(ruby, &req, resources)?),
        None => Request::Typed(Box::new(req)),
    };
    Ok((request, egress_proxy))
}

fn usage_into(ruby: &Ruby, h: RHash, metadata: Option<&ExecutionMetadata>) -> Result<(), Error> {
    let usage = metadata.and_then(|metadata| metadata.resource_usage);
    let cpu_time =
        usage.map(|usage| (usage.user_cpu_time_us + usage.system_cpu_time_us) as f64 / 1_000_000.0);
    let limit = usage.and_then(|usage| usage.limit_exceeded).map(|limit| {
        ruby.to_symbol(match limit {
            ResourceLimit::CpuTime => "cpu_time",
            ResourceLimit::Memory => "memory",
            ResourceLimit::MaxProcesses => "processes",
        })
    });
    h.aset(ruby.to_symbol("cpu_time"), cpu_time)?;
    h.aset(ruby.to_symbol("limit_exceeded"), limit)?;
    Ok(())
}

fn build_request(
    ruby: &Ruby,
    command: String,
    opts: RHash,
) -> Result<(ContainerRequest, Option<EgressProxy>), Error> {
    let mut req = ContainerRequest::new(command);
    req.timeout_ms = opt::<u32>(ruby, opts, "timeout_ms")?;
    req.working_directory = opt::<String>(ruby, opts, "working_directory")?;
    if let Some(env) = opt::<RHash>(ruby, opts, "environment")? {
        let mut pairs = Vec::new();
        env.foreach(|k: String, v: String| {
            pairs.push((k, v));
            Ok(magnus::r_hash::ForEach::Continue)
        })?;
        req.environment = Some(pairs);
    }
    req.filesystem = Some(FilesystemPolicy {
        readonly_paths: opt::<Vec<String>>(ruby, opts, "readonly")?.unwrap_or_default(),
        readwrite_paths: opt::<Vec<String>>(ruby, opts, "readwrite")?.unwrap_or_default(),
        denied_paths: opt::<Vec<String>>(ruby, opts, "denied")?.unwrap_or_default(),
        ..Default::default()
    });

    let mut egress_proxy = None;
    let egress = match opt::<Vec<String>>(ruby, opts, "allow")? {
        Some(hosts) => {
            let allowlist = Allowlist::parse(&hosts).map_err(|m| arg_error(ruby, m))?;
            let started = EgressProxy::start(allowlist).map_err(|e| io_error(ruby, e))?;
            let runtime_config = NetworkRuntimeConfig {
                network_proxy: Some(started.url()),
            };
            egress_proxy = Some(started);
            NetworkPolicy {
                egress: Some(deny_all()),
                runtime_config: Some(runtime_config),
                ..Default::default()
            }
        }
        None if opt::<bool>(ruby, opts, "network")?.unwrap_or(false) => NetworkPolicy {
            egress: Some(NetworkEgressPolicy {
                default: Some(NetworkAction::Allow),
                ..Default::default()
            }),
            ..Default::default()
        },
        None => NetworkPolicy {
            egress: Some(deny_all()),
            ..Default::default()
        },
    };
    req.network = Some(egress);

    if let Some(backend) = opt::<Symbol>(ruby, opts, "backend")? {
        req.containment = match backend.name()?.as_ref() {
            "auto" => Containment::Process,
            "bubblewrap" => Containment::Bubblewrap,
            "seatbelt" => Containment::Seatbelt(SeatbeltConfig::default()),
            "process_container" => {
                Containment::ProcessContainer(ProcessContainerConfig::default())
            }
            other => return Err(arg_error(ruby, format!("unknown backend :{other}"))),
        };
    }
    Ok((req, egress_proxy))
}

// A wait that fails, such as for a sandbox that never started the command,
// is reported as `failure` rather than raised, so Ruby reads it alongside
// what the sandbox printed.
fn outcome_hash(ruby: &Ruby, outcome: std::io::Result<WaitResult>) -> Result<RHash, Error> {
    let h = ruby.hash_new();
    let (timed_out, exit_code) = match outcome {
        Ok(WaitResult::Exited(code)) => (false, Some(code)),
        Ok(WaitResult::TimedOut) => (true, None),
        Err(e) => {
            h.aset(ruby.to_symbol("failure"), e.to_string())?;
            (false, None)
        }
    };
    h.aset(ruby.to_symbol("timed_out"), timed_out)?;
    h.aset(ruby.to_symbol("exit_code"), exit_code)?;
    Ok(h)
}

type Outcome = (std::io::Result<WaitResult>, Vec<String>, Option<ExecutionMetadata>);
type Drain = std::thread::JoinHandle<std::io::Result<Vec<u8>>>;

fn drain(stream: Option<Box<dyn Read + Send>>) -> Drain {
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(mut stream) = stream {
            stream.read_to_end(&mut buf)?;
        }
        Ok(buf)
    })
}

fn drained(handle: Drain) -> std::io::Result<Vec<u8>> {
    handle
        .join()
        .unwrap_or_else(|_| Err(std::io::Error::other("output capture thread panicked")))
}

// MXC's `wait_with_output`, except that a failed wait keeps the output: when
// Bubblewrap cannot set a sandbox up, its reason is on stderr.
fn capture(mut child: MxcProcess) -> std::io::Result<(Outcome, Vec<u8>, Vec<u8>)> {
    let closers = [child.stdout_closer(), child.stderr_closer()];
    let stdout = drain(child.take_stdout());
    let stderr = drain(child.take_stderr());
    let outcome = child.wait();
    let warnings = child.warnings();
    let metadata = child.output_metadata().cloned();
    drop(child);
    if outcome.is_err() {
        drain_until(|| stdout.is_finished() && stderr.is_finished());
    }
    if !matches!(outcome, Ok(WaitResult::Exited(_))) {
        for closer in closers.iter().flatten() {
            closer.close();
        }
    }
    Ok(((outcome, warnings, metadata), drained(stdout)?, drained(stderr)?))
}

fn snake_case(name: &str) -> String {
    let mut out = String::new();
    for (i, c) in name.chars().enumerate() {
        if c.is_ascii_uppercase() {
            if i > 0 {
                out.push('_');
            }
            out.push(c.to_ascii_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

fn backends(ruby: &Ruby) -> Result<RArray, Error> {
    let found = without_gvl(v1::available_backends);
    let arr = ruby.ary_new();
    for b in found {
        let h = ruby.hash_new();
        h.aset(ruby.to_symbol("name"), ruby.to_symbol(&b.backend))?;
        h.aset(ruby.to_symbol("tier"), b.tier)?;
        let capabilities = ruby.ary_new();
        for c in &b.capabilities {
            capabilities.push(ruby.to_symbol(snake_case(&format!("{c:?}"))))?;
        }
        h.aset(ruby.to_symbol("capabilities"), capabilities)?;
        h.aset(ruby.to_symbol("warnings"), b.warnings)?;
        arr.push(h)?;
    }
    Ok(arr)
}

fn run(ruby: &Ruby, command: String, opts: RHash) -> Result<RHash, Error> {
    let (req, mut egress_proxy) = prepare(ruby, command, opts)?;
    let result = without_gvl(move || req.spawn().map(capture));
    let blocked = egress_proxy.as_mut().map(|p| {
        p.stop();
        p.blocked()
    });
    let ((outcome, warnings, metadata), stdout, stderr) = result
        .map_err(|e| mxc_error(ruby, e))?
        .map_err(|e| io_error(ruby, e))?;
    let h = outcome_hash(ruby, outcome)?;
    h.aset(ruby.to_symbol("stdout"), ruby.str_from_slice(&stdout))?;
    h.aset(ruby.to_symbol("stderr"), ruby.str_from_slice(&stderr))?;
    h.aset(ruby.to_symbol("warnings"), warnings)?;
    h.aset(ruby.to_symbol("blocked"), blocked.unwrap_or_default())?;
    usage_into(ruby, h, metadata.as_ref())?;
    Ok(h)
}

type Reader = Mutex<Option<Box<dyn Read + Send>>>;

#[magnus::wrap(class = "MXC::Native::Process", free_immediately, size)]
struct Process {
    pid: u32,
    deadline: Option<Instant>,
    child: Mutex<Option<MxcProcess>>,
    stdin: Mutex<Option<Box<dyn Write + Send>>>,
    stdout: Reader,
    stderr: Reader,
    stdout_closer: Option<StreamCloser>,
    stderr_closer: Option<StreamCloser>,
    egress_proxy: Mutex<Option<EgressProxy>>,
}

fn spawn(ruby: &Ruby, command: String, opts: RHash) -> Result<Process, Error> {
    let timeout = opt::<u32>(ruby, opts, "timeout_ms")?.map(|ms| Duration::from_millis(ms.into()));
    let (req, egress_proxy) = prepare(ruby, command, opts)?;
    let mut child = without_gvl(move || req.spawn()).map_err(|e| mxc_error(ruby, e))?;
    Ok(Process {
        pid: child.id(),
        deadline: timeout.map(|t| Instant::now() + t),
        stdin: Mutex::new(child.take_stdin()),
        stdout: Mutex::new(child.take_stdout()),
        stderr: Mutex::new(child.take_stderr()),
        stdout_closer: child.stdout_closer(),
        stderr_closer: child.stderr_closer(),
        child: Mutex::new(Some(child)),
        egress_proxy: Mutex::new(egress_proxy),
    })
}

fn read_from(ruby: &Ruby, stream: &Reader, max: usize) -> Result<Option<RString>, Error> {
    let res = without_gvl(|| {
        let mut guard = stream.lock().unwrap();
        match guard.as_mut() {
            None => Ok(None),
            Some(r) => {
                let mut buf = vec![0u8; max];
                let n = r.read(&mut buf)?;
                buf.truncate(n);
                if n == 0 {
                    guard.take();
                }
                Ok(Some(buf))
            }
        }
    });
    match res {
        Ok(Some(buf)) if !buf.is_empty() => Ok(Some(ruby.str_from_slice(&buf))),
        Ok(_) => Ok(None),
        Err(e) => Err(io_error(ruby, e)),
    }
}

impl Process {
    fn pid(&self) -> u32 {
        self.pid
    }

    // A reader blocked in `read` holds its stream's lock, and one that reached
    // the end leaves `None`.
    fn drained(&self) -> bool {
        [&self.stdout, &self.stderr]
            .iter()
            .all(|stream| matches!(stream.try_lock(), Ok(guard) if guard.is_none()))
    }

    fn read_stdout(ruby: &Ruby, rb_self: &Self, max: usize) -> Result<Option<RString>, Error> {
        read_from(ruby, &rb_self.stdout, max)
    }

    fn read_stderr(ruby: &Ruby, rb_self: &Self, max: usize) -> Result<Option<RString>, Error> {
        read_from(ruby, &rb_self.stderr, max)
    }

    fn write(ruby: &Ruby, rb_self: &Self, data: RString) -> Result<usize, Error> {
        let bytes = unsafe { data.as_slice() }.to_vec();
        let res = without_gvl(|| {
            let mut guard = rb_self.stdin.lock().unwrap();
            match guard.as_mut() {
                None => Err(std::io::Error::other("stdin is closed")),
                Some(w) => w
                    .write_all(&bytes)
                    .and_then(|_| w.flush())
                    .map(|_| bytes.len()),
            }
        });
        res.map_err(|e| io_error(ruby, e))
    }

    fn close_stdin(&self) {
        self.stdin.lock().unwrap().take();
    }

    fn kill(ruby: &Ruby, rb_self: &Self) -> Result<(), Error> {
        let mut guard = rb_self.child.lock().unwrap();
        match guard.as_mut() {
            Some(c) => c.kill().map_err(|e| io_error(ruby, e)),
            None => Ok(()),
        }
    }

    // MxcProcess::kill and ::wait both need the handle exclusively, so waiting
    // polls and releases the lock between polls to let kill in.
    fn await_exit(&self) -> std::io::Result<Outcome> {
        let mut nap = Duration::from_millis(1);
        loop {
            {
                let mut guard = self.child.lock().unwrap();
                let child = guard
                    .as_mut()
                    .ok_or_else(|| std::io::Error::other("the process was already waited for"))?;
                let expired = self.deadline.is_some_and(|d| Instant::now() >= d);
                if expired || !matches!(child.try_wait(), Ok(None)) {
                    let outcome = child.wait();
                    let warnings = child.warnings();
                    let metadata = child.output_metadata().cloned();
                    guard.take();
                    return Ok((outcome, warnings, metadata));
                }
            }
            let mut sleep = nap;
            if let Some(deadline) = self.deadline {
                sleep = sleep.min(deadline.saturating_duration_since(Instant::now()));
            }
            std::thread::sleep(sleep);
            nap = (nap * 2).min(MAX_POLL);
        }
    }

    fn wait(ruby: &Ruby, rb_self: &Self) -> Result<RHash, Error> {
        let res = without_gvl(|| rb_self.await_exit());
        let blocked = match rb_self.egress_proxy.lock().unwrap().take() {
            Some(mut p) => {
                p.stop();
                p.blocked()
            }
            None => Vec::new(),
        };
        let (outcome, warnings, metadata) = res.map_err(|e| io_error(ruby, e))?;
        if outcome.is_err() {
            without_gvl(|| drain_until(|| rb_self.drained()));
        }
        if !matches!(outcome, Ok(WaitResult::Exited(_))) {
            if let Some(c) = &rb_self.stdout_closer {
                c.close();
            }
            if let Some(c) = &rb_self.stderr_closer {
                c.close();
            }
        }
        let h = outcome_hash(ruby, outcome)?;
        h.aset(ruby.to_symbol("warnings"), warnings)?;
        h.aset(ruby.to_symbol("blocked"), blocked)?;
        usage_into(ruby, h, metadata.as_ref())?;
        Ok(h)
    }
}

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let mxc = ruby.define_module("MXC")?;
    let native = mxc.define_module("Native")?;
    native.define_singleton_method("backends", function!(backends, 0))?;
    native.define_singleton_method("run", function!(run, 2))?;
    native.define_singleton_method("spawn", function!(spawn, 2))?;
    let process = native.define_class("Process", ruby.class_object())?;
    process.define_method("pid", method!(Process::pid, 0))?;
    process.define_method("read_stdout", method!(Process::read_stdout, 1))?;
    process.define_method("read_stderr", method!(Process::read_stderr, 1))?;
    process.define_method("write", method!(Process::write, 1))?;
    process.define_method("close_stdin", method!(Process::close_stdin, 0))?;
    process.define_method("kill", method!(Process::kill, 0))?;
    process.define_method("wait", method!(Process::wait, 0))?;
    Ok(())
}
