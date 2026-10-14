use std::ffi::c_void;
use std::io::{Read, Write};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use magnus::{
    function, method, prelude::*, Error, RArray, RHash, RModule, RString, Ruby, Symbol,
};
use mxc_sdk::v1::{
    self, configs::SeatbeltConfig, Containment, ContainerRequest, FilesystemPolicy, MxcProcess,
    NetworkAction, NetworkEgressPolicy, NetworkPolicy, NetworkRuntimeConfig, StreamCloser,
    WaitResult,
};

mod proxy;

use proxy::{Allowlist, EgressProxy};

const MAX_POLL: Duration = Duration::from_millis(50);

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
            other => return Err(arg_error(ruby, format!("unknown backend :{other}"))),
        };
    }
    Ok((req, egress_proxy))
}

fn outcome_hash(ruby: &Ruby, outcome: WaitResult) -> Result<RHash, Error> {
    let h = ruby.hash_new();
    match outcome {
        WaitResult::Exited(code) => {
            h.aset(ruby.to_symbol("timed_out"), false)?;
            h.aset(ruby.to_symbol("exit_code"), code)?;
        }
        WaitResult::TimedOut => {
            h.aset(ruby.to_symbol("timed_out"), true)?;
            h.aset(ruby.to_symbol("exit_code"), ruby.qnil())?;
        }
    }
    Ok(h)
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
    let (req, mut egress_proxy) = build_request(ruby, command, opts)?;
    let result = without_gvl(move || v1::run(req, Default::default()));
    let blocked = egress_proxy.as_mut().map(|p| {
        p.stop();
        p.blocked()
    });
    let r = result.map_err(|e| mxc_error(ruby, e))?;
    let h = outcome_hash(ruby, r.outcome)?;
    h.aset(ruby.to_symbol("stdout"), ruby.str_from_slice(&r.stdout))?;
    h.aset(ruby.to_symbol("stderr"), ruby.str_from_slice(&r.stderr))?;
    h.aset(ruby.to_symbol("warnings"), r.warnings)?;
    h.aset(ruby.to_symbol("blocked"), blocked.unwrap_or_default())?;
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
    let (req, egress_proxy) = build_request(ruby, command, opts)?;
    let timeout = req.timeout_ms.map(|ms| Duration::from_millis(ms.into()));
    let mut child = without_gvl(move || v1::spawn(req, Default::default()))
        .map_err(|e| mxc_error(ruby, e))?;
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
    fn await_exit(&self) -> std::io::Result<(WaitResult, Vec<String>)> {
        let mut nap = Duration::from_millis(1);
        loop {
            {
                let mut guard = self.child.lock().unwrap();
                let child = guard
                    .as_mut()
                    .ok_or_else(|| std::io::Error::other("the process was already waited for"))?;
                let expired = self.deadline.is_some_and(|d| Instant::now() >= d);
                if expired || child.try_wait()?.is_some() {
                    let outcome = child.wait()?;
                    let warnings = child.warnings();
                    guard.take();
                    return Ok((outcome, warnings));
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
        let (outcome, warnings) = res.map_err(|e| io_error(ruby, e))?;
        if !matches!(outcome, WaitResult::Exited(_)) {
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
