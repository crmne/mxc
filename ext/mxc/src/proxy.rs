use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const MAX_HEADER: usize = 16 * 1024;
const HEADER_TIMEOUT: Duration = Duration::from_secs(30);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_PORTS: [u16; 2] = [80, 443];

#[derive(Debug, Clone, PartialEq, Eq)]
enum HostPattern {
    Exact(String),
    Suffix(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Rule {
    host: HostPattern,
    ports: Vec<u16>,
}

#[derive(Debug, Clone, Default)]
pub struct Allowlist {
    rules: Vec<Rule>,
}

fn normalize_host(host: &str) -> String {
    host.trim()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .trim_end_matches('.')
        .to_ascii_lowercase()
}

fn split_host_port(entry: &str) -> (&str, Option<&str>) {
    if let Some(rest) = entry.strip_prefix('[') {
        if let Some(end) = rest.find(']') {
            let port = rest[end + 1..].strip_prefix(':');
            return (&rest[..end], port);
        }
    }
    match entry.rsplit_once(':') {
        Some((host, port)) if !host.contains(':') => (host, Some(port)),
        _ => (entry, None),
    }
}

impl Allowlist {
    pub fn parse(entries: &[String]) -> Result<Self, String> {
        let mut rules = Vec::new();
        for raw in entries {
            let (host, port) = split_host_port(raw.trim());
            let host = normalize_host(host);
            if host.is_empty() || host.contains('/') || host.contains(char::is_whitespace) {
                return Err(format!("invalid allow entry {raw:?}"));
            }
            let ports = match port {
                Some(p) => vec![p
                    .parse::<u16>()
                    .ok()
                    .filter(|p| *p != 0)
                    .ok_or_else(|| format!("invalid port in allow entry {raw:?}"))?],
                None => DEFAULT_PORTS.to_vec(),
            };
            let host = match host.strip_prefix("*.") {
                Some(suffix) if !suffix.is_empty() && !suffix.contains('*') => {
                    HostPattern::Suffix(suffix.to_string())
                }
                _ if host.contains('*') => {
                    return Err(format!(
                        "invalid allow entry {raw:?}: only a leading \"*.\" wildcard is supported"
                    ))
                }
                _ => HostPattern::Exact(host),
            };
            rules.push(Rule { host, ports });
        }
        Ok(Self { rules })
    }

    pub fn permits(&self, host: &str, port: u16) -> bool {
        let host = normalize_host(host);
        self.rules.iter().any(|rule| {
            rule.ports.contains(&port)
                && match &rule.host {
                    HostPattern::Exact(h) => *h == host,
                    HostPattern::Suffix(s) => {
                        host.len() > s.len() + 1
                            && host.ends_with(s.as_str())
                            && host.as_bytes()[host.len() - s.len() - 1] == b'.'
                    }
                }
        })
    }

    fn explicitly_lists_ip(&self, ip: &IpAddr) -> bool {
        let literal = ip.to_string();
        self.rules
            .iter()
            .any(|rule| matches!(&rule.host, HostPattern::Exact(h) if *h == literal))
    }

    pub fn address_permitted(&self, ip: &IpAddr) -> bool {
        is_public(ip) || self.explicitly_lists_ip(ip)
    }
}

pub fn is_public(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_public_v4(v4),
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => is_public_v4(&v4),
            None => is_public_v6(v6),
        },
    }
}

fn is_public_v4(ip: &Ipv4Addr) -> bool {
    let o = ip.octets();
    !(ip.is_unspecified()
        || ip.is_loopback()
        || ip.is_private()
        || ip.is_link_local()
        || ip.is_broadcast()
        || ip.is_multicast()
        || ip.is_documentation()
        || o[0] == 0
        || (o[0] == 100 && (o[1] & 0xc0) == 64)
        || (o[0] == 192 && o[1] == 0 && o[2] == 0)
        || (o[0] == 198 && (o[1] & 0xfe) == 18)
        || o[0] >= 240)
}

fn is_public_v6(ip: &Ipv6Addr) -> bool {
    let s = ip.segments();
    !(ip.is_unspecified()
        || ip.is_loopback()
        || ip.is_multicast()
        || (s[0] & 0xfe00) == 0xfc00
        || (s[0] & 0xffc0) == 0xfe80
        || (s[0] == 0x2001 && s[1] == 0x0db8)
        || (s[0] == 0x64 && s[1] == 0xff9b))
}

struct Shared {
    allowlist: Allowlist,
    stopping: AtomicBool,
    connections: Mutex<Vec<TcpStream>>,
    blocked: Mutex<Vec<String>>,
}

pub struct EgressProxy {
    addr: SocketAddr,
    shared: Arc<Shared>,
    acceptor: Option<JoinHandle<()>>,
}

impl EgressProxy {
    pub fn start(allowlist: Allowlist) -> io::Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        let addr = listener.local_addr()?;
        let shared = Arc::new(Shared {
            allowlist,
            stopping: AtomicBool::new(false),
            connections: Mutex::new(Vec::new()),
            blocked: Mutex::new(Vec::new()),
        });
        let accept_shared = Arc::clone(&shared);
        let acceptor = thread::Builder::new()
            .name("mxc-egress-proxy".into())
            .spawn(move || accept_loop(listener, accept_shared))?;
        Ok(Self {
            addr,
            shared,
            acceptor: Some(acceptor),
        })
    }

    pub fn url(&self) -> String {
        format!("http://{}", self.addr)
    }

    pub fn blocked(&self) -> Vec<String> {
        self.shared.blocked.lock().unwrap().clone()
    }

    pub fn stop(&mut self) {
        if self.shared.stopping.swap(true, Ordering::SeqCst) {
            return;
        }
        let _ = TcpStream::connect_timeout(&self.addr, Duration::from_millis(200));
        if let Some(handle) = self.acceptor.take() {
            let _ = handle.join();
        }
        for conn in self.shared.connections.lock().unwrap().drain(..) {
            let _ = conn.shutdown(Shutdown::Both);
        }
    }
}

impl Drop for EgressProxy {
    fn drop(&mut self) {
        self.stop();
    }
}

fn accept_loop(listener: TcpListener, shared: Arc<Shared>) {
    for stream in listener.incoming() {
        if shared.stopping.load(Ordering::SeqCst) {
            break;
        }
        let Ok(stream) = stream else { continue };
        let conn_shared = Arc::clone(&shared);
        let _ = thread::Builder::new()
            .name("mxc-egress-conn".into())
            .spawn(move || {
                let _ = handle(stream, &conn_shared);
            });
    }
}

fn track(shared: &Shared, stream: &TcpStream) {
    if let Ok(clone) = stream.try_clone() {
        let mut conns = shared.connections.lock().unwrap();
        conns.retain(|c| c.peer_addr().is_ok());
        conns.push(clone);
    }
}

struct Head {
    method: String,
    target: String,
    version: String,
    headers: Vec<(String, String)>,
    rest: Vec<u8>,
}

fn read_head(stream: &mut TcpStream) -> io::Result<Head> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 2048];
    let end = loop {
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos;
        }
        if buf.len() > MAX_HEADER {
            return Err(io::Error::other("request header too large"));
        }
        let n = stream.read(&mut chunk)?;
        if n == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "closed"));
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let text = std::str::from_utf8(&buf[..end]).map_err(|_| io::Error::other("bad header"))?;
    let mut lines = text.split("\r\n");
    let mut parts = lines.next().unwrap_or_default().split(' ');
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();
    let version = parts.next().unwrap_or("HTTP/1.1").to_string();
    let headers = lines
        .filter_map(|l| l.split_once(':'))
        .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
        .collect();
    Ok(Head {
        method,
        target,
        version,
        headers,
        rest: buf[end + 4..].to_vec(),
    })
}

fn respond(stream: &mut TcpStream, status: &str, body: &str) {
    let _ = write!(
        stream,
        "HTTP/1.1 {status}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}

fn parse_authority(authority: &str, default_port: u16) -> Option<(String, u16)> {
    let (host, port) = split_host_port(authority);
    let port = match port {
        Some(p) => p.parse().ok()?,
        None => default_port,
    };
    let host = normalize_host(host);
    (!host.is_empty()).then_some((host, port))
}

fn parse_absolute_http(target: &str) -> Option<(String, u16, String)> {
    let rest = target
        .get(..7)
        .filter(|s| s.eq_ignore_ascii_case("http://"))
        .map(|_| &target[7..])?;
    let (authority, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    let authority = authority.rsplit('@').next()?;
    let (host, port) = parse_authority(authority, 80)?;
    Some((host, port, path.to_string()))
}

fn dial(shared: &Shared, host: &str, port: u16) -> Result<TcpStream, String> {
    let addrs: Vec<SocketAddr> = (host, port)
        .to_socket_addrs()
        .map_err(|e| format!("cannot resolve {host}: {e}"))?
        .collect();
    let permitted: Vec<&SocketAddr> = addrs
        .iter()
        .filter(|a| shared.allowlist.address_permitted(&a.ip()))
        .collect();
    if permitted.is_empty() {
        return Err(format!(
            "{host} resolves only to non-public addresses ({})",
            addrs.iter().map(|a| a.ip().to_string()).collect::<Vec<_>>().join(", ")
        ));
    }
    let mut last = String::new();
    for addr in permitted {
        match TcpStream::connect_timeout(addr, CONNECT_TIMEOUT) {
            Ok(s) => return Ok(s),
            Err(e) => last = format!("{addr}: {e}"),
        }
    }
    Err(format!("cannot connect to {host}:{port}: {last}"))
}

fn deny(shared: &Shared, stream: &mut TcpStream, host: &str, port: u16, why: &str) {
    shared.blocked.lock().unwrap().push(format!("{host}:{port}"));
    respond(
        stream,
        "403 Forbidden",
        &format!("mxc: egress to {host}:{port} is not allowed ({why})\n"),
    );
}

fn handle(mut client: TcpStream, shared: &Shared) -> io::Result<()> {
    track(shared, &client);
    client.set_read_timeout(Some(HEADER_TIMEOUT))?;
    let head = read_head(&mut client)?;
    client.set_read_timeout(None)?;

    if head.method.eq_ignore_ascii_case("CONNECT") {
        let Some((host, port)) = parse_authority(&head.target, 443) else {
            respond(&mut client, "400 Bad Request", "mxc: bad CONNECT target\n");
            return Ok(());
        };
        if !shared.allowlist.permits(&host, port) {
            deny(shared, &mut client, &host, port, "not in allow list");
            return Ok(());
        }
        let mut upstream = match dial(shared, &host, port) {
            Ok(s) => s,
            Err(why) => {
                deny(shared, &mut client, &host, port, &why);
                return Ok(());
            }
        };
        track(shared, &upstream);
        client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n")?;
        upstream.write_all(&head.rest)?;
        return splice(client, upstream);
    }

    let Some((host, port, path)) = parse_absolute_http(&head.target) else {
        respond(
            &mut client,
            "400 Bad Request",
            "mxc: expected CONNECT or an absolute http:// URL\n",
        );
        return Ok(());
    };
    if !shared.allowlist.permits(&host, port) {
        deny(shared, &mut client, &host, port, "not in allow list");
        return Ok(());
    }
    let mut upstream = match dial(shared, &host, port) {
        Ok(s) => s,
        Err(why) => {
            deny(shared, &mut client, &host, port, &why);
            return Ok(());
        }
    };
    track(shared, &upstream);
    let mut out = format!("{} {} {}\r\n", head.method, path, head.version);
    for (k, v) in &head.headers {
        let lower = k.to_ascii_lowercase();
        if lower == "proxy-connection" || lower == "proxy-authorization" || lower == "connection" {
            continue;
        }
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    out.push_str("Connection: close\r\n\r\n");
    upstream.write_all(out.as_bytes())?;
    upstream.write_all(&head.rest)?;
    splice(client, upstream)
}

fn splice(client: TcpStream, upstream: TcpStream) -> io::Result<()> {
    let mut c_read = client.try_clone()?;
    let mut u_write = upstream.try_clone()?;
    let up = thread::spawn(move || {
        let _ = io::copy(&mut c_read, &mut u_write);
        let _ = u_write.shutdown(Shutdown::Write);
    });
    let mut u_read = upstream;
    let mut c_write = client;
    let _ = io::copy(&mut u_read, &mut c_write);
    let _ = c_write.shutdown(Shutdown::Write);
    let _ = up.join();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(entries: &[&str]) -> Allowlist {
        Allowlist::parse(&entries.iter().map(|s| s.to_string()).collect::<Vec<_>>()).unwrap()
    }

    #[test]
    fn exact_hosts_on_default_ports() {
        let l = list(&["PyPI.org."]);
        assert!(l.permits("pypi.org", 443));
        assert!(l.permits("pypi.org", 80));
        assert!(!l.permits("pypi.org", 22));
        assert!(!l.permits("evilpypi.org", 443));
        assert!(!l.permits("files.pypi.org", 443));
    }

    #[test]
    fn wildcard_matches_subdomains_only() {
        let l = list(&["*.pythonhosted.org"]);
        assert!(l.permits("files.pythonhosted.org", 443));
        assert!(!l.permits("pythonhosted.org", 443));
        assert!(!l.permits("evilpythonhosted.org", 443));
    }

    #[test]
    fn explicit_port() {
        let l = list(&["example.com:8443", "[2001:db8::1]:443"]);
        assert!(l.permits("example.com", 8443));
        assert!(!l.permits("example.com", 443));
        assert!(l.permits("[2001:db8::1]", 443));
    }

    #[test]
    fn rejects_bad_entries() {
        for bad in ["", "a b", "10.0.0.0/8", "foo.*.com", "x:0", "x:http"] {
            assert!(Allowlist::parse(&[bad.to_string()]).is_err(), "{bad}");
        }
    }

    #[test]
    fn private_addresses_are_refused_unless_listed() {
        let l = list(&["internal.example", "10.1.2.3"]);
        for ip in ["127.0.0.1", "10.0.0.5", "169.254.169.254", "::1", "fd00::1", "::ffff:127.0.0.1", "100.64.0.1"] {
            assert!(!l.address_permitted(&ip.parse().unwrap()), "{ip}");
        }
        assert!(l.address_permitted(&"10.1.2.3".parse().unwrap()));
        assert!(l.address_permitted(&"151.101.0.223".parse().unwrap()));
        assert!(l.address_permitted(&"2a04:4e42::223".parse().unwrap()));
    }

    #[test]
    fn absolute_http_targets() {
        assert_eq!(
            parse_absolute_http("http://user@Example.com:8080/a?b"),
            Some(("example.com".into(), 8080, "/a?b".into()))
        );
        assert_eq!(parse_absolute_http("http://example.com"), Some(("example.com".into(), 80, "/".into())));
        assert_eq!(parse_absolute_http("/relative"), None);
    }
}
