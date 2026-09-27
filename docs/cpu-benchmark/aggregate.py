#!/usr/bin/env python3
"""Where the on-CPU time of a Time Profiler trace went.

    aggregate.py <profile.xml> [seconds]
    THREAD="spotifly.decode" aggregate.py <profile.xml>   # one thread only

Reads the XML that `xctrace export` writes for the `time-profile` table and sums
sample weights by thread, by the binary and function at the top of the stack, and
by every binary and function anywhere in it. The export writes each value once
with an `id` and refers back to it with `ref`, so everything is resolved through
one table of ids.
"""

import collections
import os
import re
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
only_thread = os.environ.get("THREAD")
by_id = {}


def resolve(element):
    ref = element.get("ref")
    return by_id[ref] if ref is not None else element


def remember(element):
    if element.get("id") is not None:
        by_id[element.get("id")] = element
    for child in element:
        remember(child)


threads, top_function, top_binary, any_binary, any_function = (collections.Counter() for _ in range(5))
total = 0.0
for _, row in ET.iterparse(path):
    if row.tag != "row":
        continue
    remember(row)
    thread = weight = backtrace = None
    for child in row:
        value = resolve(child)
        if child.tag == "thread":
            thread = re.sub(r"\s*\(.*\)$", "", re.sub(r"\s*0x[0-9a-f]+", "", value.get("fmt", "?")))
        elif child.tag == "weight":
            weight = float(value.text) / 1e6  # ns -> ms
        elif child.tag in ("backtrace", "tagged-backtrace"):
            backtrace = value
    if weight is None or (only_thread and thread != only_thread):
        row.clear()
        continue

    total += weight
    threads[thread] += weight
    frames = []
    for frame in backtrace if backtrace is not None else []:
        if frame.tag != "frame":
            continue
        frame = resolve(frame)
        binary = next((resolve(b).get("name", "?") for b in frame if b.tag == "binary"), "?")
        frames.append((frame.get("name", "?"), binary))
    if frames:
        top_function[f"{frames[0][0]}  [{frames[0][1]}]"] += weight
        top_binary[frames[0][1]] += weight
    for binary in {binary for _, binary in frames}:
        any_binary[binary] += weight
    for name in {f"{name}  [{binary}]" for name, binary in frames}:
        any_function[name] += weight
    row.clear()


def show(title, counter, limit):
    print(f"\n## {title}")
    for key, ms in counter.most_common(limit):
        print(f"{ms:9.1f} ms  {100 * ms / total:5.1f}%  {key}")


print(f"on-CPU samples: {total:.0f} ms over {seconds:.0f} s = {100 * total / 1000 / seconds:.2f}% of one core")
show("By thread", threads, 15)
show("By binary at the top of the stack (self time)", top_binary, 15)
show("By function at the top of the stack (self time)", top_function, 25)
show("By binary anywhere in the stack (inclusive)", any_binary, 20)
show("By function anywhere in the stack (inclusive)", any_function, 45)
own = collections.Counter({k: v for k, v in any_function.items() if k.endswith("[Spotifly]")})
show("Spotifly's own frames anywhere in the stack (inclusive)", own, 40)
