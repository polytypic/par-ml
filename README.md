# Experimental parallel and concurrent OCaml

_*NOTE*_: There are multiple different approaches implemented in this
repository. See the different
[branches](https://github.com/polytypic/par-ml/branches/all).

This particular approach uses the DCYL work-stealing deque on top of the
[`idle-domains`](https://github.com/polytypic/idle-domains) library. This gives
reasonable overhead and good parallelization of the last few work items.

Key differences compared to
[lockfree](https://github.com/ocaml-multicore/lockfree) work-stealing deque and
the version implemented [here](src/main/DCYL.ml):

- Padding is added, see the
  [`multicore-magic`](https://github.com/polytypic/multicore-magic) library, to
  long-lived objects to avoid false-sharing.
- Only a single atomic variable is used (closer to
  [original paper](https://www.semanticscholar.org/paper/Dynamic-circular-work-stealing-deque-Chase-Lev/f856a996e7aec0ea6db55e9247a00a01cb695090)).
- A level of (pointer) indirection is avoided by using a different technique to
  release stolen elements (look for `clear_stolen`).
- [`mark` and `drop_at` operations](src/main/DCYL.mli) are provided to allow
  owner to remove elements from deque without dropping to main loop.

Key differences compared to the worker pool of
[domainslib](https://github.com/ocaml-multicore/domainslib) and the approach
implemented [here](src/main/Par.ml):

- A more general `Suspend` effect is used to allow synchronization primitives to
  be built on top of the scheduler.
- The pool of workers is not exposed. The idea is that there is only one system
  level pool of workers, provided by
  [`idle-domains`](https://github.com/polytypic/idle-domains) to be used by all
  parallel and concurrent code.
  - `Domain.self ()` is used as index for efficient per domain storage. The
    domain ids are assumed to be consecutive numbers in the range `[0, n[`.
- A lower overhead [`par`](src/main/Par.mli) operation is provided for parallel
  execution.
- Work items are defunctionalized replacing a closure with an existential inside
  an atomic.
- The [`idle-domains`](https://github.com/polytypic/idle-domains) library is
  used for parking and waking up workers based on operations it provides.

It would seem that the ability to drop work items from the owned deque, and
thereby avoid accumulation of stale work items, and, at the same time, ability
to avoid capturing continuations, can provide major performance benefits
(roughly 5x) in cases where it applies. Other optimizations provide a small
benefits (roughly 2x).

Avoiding false-sharing is crucial for stable performance.

TODO:

- Support for cancellation.
- `sleep` mechanism.
- Composable synchronization primitives (e.g. ability to `race` fibers).
- Various synchronization primitives (mutex, condition, ...) as examples.

## Benchmarks to be taken with plenty of salt

These have been run on Apple M1 with 4 + 4 cores (in normal mode).

> As an aside, let's assume cache size differences do not matter. As Apple M1
> has 4 cores at 3228 MHz and 4 cores at 2064 MHz, one could estimate that the
> best possible parallel speed up would be (4 \* (3228 + 2064)) / 3228 or
> roughly 6.5.

```sh
➜  P=FibFiber.exe; N=37; hyperfine --warmup 1 --shell none "$P 1 $N" "$P 2 $N" "$P 4 $N" "$P 8 $N"
Benchmark 1: FibFiber.exe 1 37
  Time (mean ± σ):      1.205 s ±  0.001 s    [User: 1.201 s, System: 0.004 s]
  Range (min … max):    1.204 s …  1.208 s    10 runs

Benchmark 2: FibFiber.exe 2 37
  Time (mean ± σ):     659.0 ms ±   0.5 ms    [User: 1304.7 ms, System: 3.9 ms]
  Range (min … max):   658.4 ms … 659.9 ms    10 runs

Benchmark 3: FibFiber.exe 4 37
  Time (mean ± σ):     354.2 ms ±   1.6 ms    [User: 1376.1 ms, System: 7.9 ms]
  Range (min … max):   352.4 ms … 357.3 ms    10 runs

Benchmark 4: FibFiber.exe 8 37
  Time (mean ± σ):     426.4 ms ±  13.4 ms    [User: 2794.3 ms, System: 84.9 ms]
  Range (min … max):   406.2 ms … 448.6 ms    10 runs

Summary
  'FibFiber.exe 4 37' ran
    1.20 ± 0.04 times faster than 'FibFiber.exe 8 37'
    1.86 ± 0.01 times faster than 'FibFiber.exe 2 37'
    3.40 ± 0.02 times faster than 'FibFiber.exe 1 37'
```

```sh
➜  P=FibPar.exe; N=37; hyperfine --warmup 1 --shell none "$P 1 $N" "$P 2 $N" "$P 4 $N" "$P 8 $N"
Benchmark 1: FibPar.exe 1 37
  Time (mean ± σ):     898.0 ms ±   0.4 ms    [User: 894.8 ms, System: 2.7 ms]
  Range (min … max):   897.4 ms … 898.7 ms    10 runs

Benchmark 2: FibPar.exe 2 37
  Time (mean ± σ):     547.9 ms ±   1.0 ms    [User: 1083.2 ms, System: 3.5 ms]
  Range (min … max):   547.1 ms … 550.6 ms    10 runs

Benchmark 3: FibPar.exe 4 37
  Time (mean ± σ):     295.1 ms ±   1.0 ms    [User: 1142.4 ms, System: 7.2 ms]
  Range (min … max):   293.7 ms … 296.9 ms    10 runs

Benchmark 4: FibPar.exe 8 37
  Time (mean ± σ):     431.7 ms ±  35.6 ms    [User: 2776.3 ms, System: 88.4 ms]
  Range (min … max):   393.6 ms … 517.7 ms    10 runs

Summary
  'FibPar.exe 4 37' ran
    1.46 ± 0.12 times faster than 'FibPar.exe 8 37'
    1.86 ± 0.01 times faster than 'FibPar.exe 2 37'
    3.04 ± 0.01 times faster than 'FibPar.exe 1 37'
```

In the following, the `fib_par` example of domainslib

```ocaml
let rec fib_par pool n =
  if n < 2 then n
  else
    let b = T.async pool (fun _ -> fib_par pool (n - 1)) in
    let a = fib_par pool (n - 2) in
    a + T.await pool b
```

has been modified as above

- to not drop down to sequential version (intention is to measure overheads),
- to perform better (using fewer `async`/`await`s), and
- to give same numerical result as the `par-ml` versions.

```sh
➜  P=fib_par.exe; N=37; hyperfine --warmup 1 --shell none "$P 1 $N" "$P 2 $N" "$P 4 $N" "$P 8 $N"
Benchmark 1: fib_par.exe 1 37
  Time (mean ± σ):      7.101 s ±  0.027 s    [User: 7.084 s, System: 0.017 s]
  Range (min … max):    7.065 s …  7.172 s    10 runs

Benchmark 2: fib_par.exe 2 37
  Time (mean ± σ):      4.647 s ±  0.038 s    [User: 9.264 s, System: 0.016 s]
  Range (min … max):    4.610 s …  4.712 s    10 runs

Benchmark 3: fib_par.exe 4 37
  Time (mean ± σ):      3.095 s ±  0.062 s    [User: 12.309 s, System: 0.018 s]
  Range (min … max):    3.028 s …  3.205 s    10 runs

Benchmark 4: fib_par.exe 8 37
  Time (mean ± σ):      4.950 s ±  0.053 s    [User: 36.023 s, System: 0.269 s]
  Range (min … max):    4.852 s …  5.040 s    10 runs

Summary
  'fib_par.exe 4 37' ran
    1.50 ± 0.03 times faster than 'fib_par.exe 2 37'
    1.60 ± 0.04 times faster than 'fib_par.exe 8 37'
    2.29 ± 0.05 times faster than 'fib_par.exe 1 37'
```
