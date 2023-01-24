(* Based on circular work-stealing deque of David Chase and Yossi Lev.

   For clarity, this renames `top` and `bottom` to `lo` and `hi` such that
   `hi - lo` is positive in case the deque is non-empty.

   Thieves (and owner) update `lo` when stealing elements from the `lo` end
   of the deque.  The owner maintains a separate `lo_cache`.  This is done to
   allow the owner to clear (or release) stolen elements for GC to work.  It
   is not safe for thieves to write to the `elems` array of the deque. *)

[@@@ocaml.warning "-69"] (* Disable unused field warning. *)

type 'a t = {
  lo : int Atomic.t;
  hi : int Atomic.t;
  (* Only the owner mutates the rest: *)
  mutable elems : 'a array;
  m3 : int;
  m4 : int;
  m5 : int;
  m6 : int;
  m7 : int;
  m8 : int;
  m9 : int;
  mA : int;
  mB : int;
  mC : int;
  mD : int;
  mE : int;
  mF : int;
  mutable lo_cache : int;
}

type pos = int

let min_capacity = 4

let mask_of array =
  (* The original unpadded array length must be a power of two. *)
  Multicore_magic.length_of_padded_array_minus_1 array
  [@@inline]

let make () =
  Multicore_magic.copy_as_padded
    {
      lo = Multicore_magic.copy_as_padded (Atomic.make 0);
      hi = Multicore_magic.copy_as_padded (Atomic.make 0);
      elems = Multicore_magic.make_padded_array min_capacity (Obj.magic ());
      m3 = 0;
      m4 = 0;
      m5 = 0;
      m6 = 0;
      m7 = 0;
      m8 = 0;
      m9 = 0;
      mA = 0;
      mB = 0;
      mC = 0;
      mD = 0;
      mE = 0;
      mF = 0;
      lo_cache = 0;
    }

let mark dcyl = Multicore_magic.fenceless_get dcyl.hi [@@inline]

let clear_or_grow_and_push dcyl ~elem ~hi ~elems ~mask =
  let lo = Multicore_magic.fenceless_get dcyl.lo in
  (* `fenceless_get lo` is safe as we do not need the latest value. *)
  let lo_cache = dcyl.lo_cache in
  if lo_cache < lo then begin
    (* Clear stolen elements to make room. *)
    dcyl.lo_cache <- lo;
    for i = lo_cache to lo - 1 do
      Array.unsafe_set elems (i land mask) (Obj.magic ())
    done;
    Array.unsafe_set elems (hi land mask) elem;
    (* `incr` ensures elem is seen before `hi` and thieves read valid. *)
    Atomic.incr dcyl.hi
  end
  else begin
    (* Grow to make room. *)
    let mask' = (mask * 2) + 1 in
    let elems' = Multicore_magic.make_padded_array (mask' + 1) (Obj.magic ()) in
    for i = lo to hi - 1 do
      Array.unsafe_set elems' (i land mask')
        (Array.unsafe_get elems (i land mask))
    done;
    dcyl.elems <- elems';
    Array.unsafe_set elems' (hi land mask') elem;
    (* `incr` ensures elem is seen before `hi` and thieves read valid. *)
    Atomic.incr dcyl.hi
  end

let push dcyl elem =
  let hi = Multicore_magic.fenceless_get dcyl.hi in
  (* `fenceless_get hi` is safe as only the owner mutates `hi`. *)
  let elems = dcyl.elems in
  let mask = mask_of elems in
  let lo_cache = dcyl.lo_cache in
  if hi - lo_cache <= mask then begin
    Array.unsafe_set elems (hi land mask) elem;
    (* `incr` ensures elem is seen before `hi` and thieves read valid. *)
    Atomic.incr dcyl.hi
  end
  else clear_or_grow_and_push dcyl ~elem ~hi ~elems ~mask
  [@@inline]

let reset_and_exit dcyl elems lo =
  if Multicore_magic.length_of_padded_array elems <> min_capacity then begin
    dcyl.lo_cache <- lo;
    dcyl.elems <- Multicore_magic.make_padded_array min_capacity (Obj.magic ())
  end
  else begin
    let lo_cache = dcyl.lo_cache in
    if lo_cache < lo then begin
      dcyl.lo_cache <- lo;
      let mask = mask_of elems in
      for i = lo_cache to lo - 1 do
        Array.unsafe_set elems (i land mask) (Obj.magic ())
      done
    end
  end;
  raise Exit

let pop dcyl =
  let hi = Atomic.fetch_and_add dcyl.hi (-1) - 1 in
  (* `fetch_and_add hi` ensures `hi` is written first to stop thieves. *)
  let lo = Multicore_magic.fenceless_get dcyl.lo in
  (* `fenceless_get lo` is safe as thieves always `compare_and_set lo`. *)
  if hi < lo then begin
    Multicore_magic.fenceless_set dcyl.hi (hi + 1);
    (* `fenceless_set hi` is safe as old value is safe for thieves. *)
    reset_and_exit dcyl dcyl.elems lo
  end
  else
    let elems = dcyl.elems in
    let mask = mask_of elems in
    let i = hi land mask in
    let elem = Array.unsafe_get elems i in
    if lo < hi then begin
      Array.unsafe_set elems i (Obj.magic ());
      elem
    end
    else
      (* Compete with thieves for last element. *)
      let got = Atomic.compare_and_set dcyl.lo lo (lo + 1) in
      Multicore_magic.fenceless_set dcyl.hi (hi + 1);
      (* `fenceless_set hi` is safe as old value is safe for thieves. *)
      if got then elem else reset_and_exit dcyl elems lo

let drop_at dcyl at =
  let hi = Multicore_magic.fenceless_get dcyl.hi - 1 in
  if hi = at then begin
    Atomic.decr dcyl.hi;
    (* `incr hi` ensures `hi` is written first to stop thieves. *)
    let lo = Multicore_magic.fenceless_get dcyl.lo in
    (* `fenceless_get lo` is safe as thieves always `compare_and_set lo?  *)
    if hi < lo then Multicore_magic.fenceless_set dcyl.hi (hi + 1)
      (* `fenceless_set hi` is safe as old value is safe for thieves. *)
    else
      let elems = dcyl.elems in
      let mask = mask_of elems in
      if lo < hi then Array.unsafe_set elems (hi land mask) (Obj.magic ())
      else begin
        (* Compete with thieves for last element. *)
        Atomic.compare_and_set dcyl.lo lo (lo + 1) |> ignore;
        Multicore_magic.fenceless_set dcyl.hi (hi + 1)
        (* `fenceless_set hi` is safe as old value is safe for thieves. *)
      end
  end

let rec steal dcyl =
  let lo = Multicore_magic.fenceless_get dcyl.lo in
  (* `fenceless_get lo` is safe as it is verified by `compare_and_set lo`. *)
  if Atomic.get dcyl.hi <= lo then raise Exit
    (* `get hi` ensures the `dcyl.elems` access below is safe. *)
  else
    let elems = dcyl.elems in
    let elem = Array.unsafe_get elems (lo land mask_of elems) in
    if Atomic.compare_and_set dcyl.lo lo (lo + 1) then
      (* Unsafe to write `Obj.magic ()` over elem here. *)
      elem
    else steal dcyl

let seems_non_empty dcyl =
  Multicore_magic.fenceless_get dcyl.lo < Multicore_magic.fenceless_get dcyl.hi
  [@@inline]
