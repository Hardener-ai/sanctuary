# PF Anchor Namespace Spike - 2026-05-05

Status: SUCCESS

Question: can Sanctuary load redirect rules under an existing Apple pf anchor namespace, `com.apple/250.SanctuaryRedirect`, without modifying `/etc/pf.conf`?

## Commands Run

Step A wrote a temporary anchor file:

```sh
printf '%s\n' 'rdr on lo0 inet proto tcp from any to 127.0.0.1 port 19222 -> 127.0.0.1 port 19223' \
  | sudo tee /etc/pf.anchors/com.apple-test.sanctuary.spike
```

Step B loaded it under the Apple anchor namespace:

```sh
sudo pfctl -a 'com.apple/250.SanctuaryRedirect' -f /etc/pf.anchors/com.apple-test.sanctuary.spike
```

Result: exit code 0. macOS printed the usual benign warnings:

```text
pfctl: Use of -f option, could result in flushing of rules
present in the main ruleset added by the system at startup.
See /etc/pf.conf for further details.

No ALTQ support in kernel
ALTQ related functions disabled
```

Step C inspected the anchor:

```sh
sudo pfctl -a 'com.apple/250.SanctuaryRedirect' -s rules
```

Result: exit code 0, but no rule text was printed. The rule is an `rdr`
translation rule, so `-s rules` is not a reliable visibility check for this
case even though the redirect was active.

Step D tested the redirect:

```sh
python3 -m http.server 19223 --bind 127.0.0.1
curl -v --max-time 3 http://127.0.0.1:19222/
```

Result: success. `curl` connected to `127.0.0.1:19222` and received a `200 OK`
from the Python server on `19223`. The Python server logged:

```text
127.0.0.1 - - [05/May/2026 07:05:29] "GET / HTTP/1.1" 200 -
```

Step E cleanup:

```sh
sudo pfctl -a 'com.apple/250.SanctuaryRedirect' -F all
sudo rm -f /etc/pf.anchors/com.apple-test.sanctuary.spike
sudo pfctl -a 'com.apple/250.SanctuaryRedirect' -s rules
```

Result: success. Flush printed:

```text
rules cleared
nat cleared
dummynet cleared
0 tables deleted.
```

Post-cleanup side-effect check:

```sh
sudo pfctl -a com.apple -s rules | head -40
```

The existing Apple anchors remained visible:

```text
anchor "200.AirDrop/*" all
anchor "250.ApplicationFirewall/*" all
```

No Sanctuary entries remained in `/etc/pf.conf`, and the temporary anchor file
was removed.

## Answers

- Did `pfctl -f` succeed under `com.apple/250.SanctuaryRedirect`? Yes.
- Did the rule appear in `pfctl -s rules` output? No; the command returned
  success but printed no rule body for this rdr rule.
- Did the redirect actually fire? Yes. `curl` to `127.0.0.1:19222` reached the
  Python server bound on `127.0.0.1:19223`.
- Did flushing clear it cleanly? Yes.
- Side effects on existing `com.apple` rules? None observed.

Decision: use `com.apple/250.SanctuaryRedirect` and remove all `/etc/pf.conf`
modification logic.
