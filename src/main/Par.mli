val run : (unit -> 'a) -> 'a
(** Run parallel / concurrent code. *)

val par : (unit -> 'a) -> (unit -> 'b) -> 'a * 'b
(** Perform the two given actions potentially in parallel.  Parallel execution
    is not guaranteed. *)

(** Co-operative threads of control. *)
module Fiber : sig
  type 'a t
  (** Represents a co-operative thread of control. *)

  val spawn : (unit -> 'a) -> 'a t
  (** Create a new fiber running the given function. *)

  val join : 'a t -> 'a
  (** Wait until the given fiber terminates and either return its final value
      or raise the exception it terminated with. *)
end

(** Exactly-once continuations. *)
module Continuation : sig
  type 'a t
  (** Represents an exactly-once continuation expecting a value of type ['a]. *)

  val suspend : ('a t -> unit) -> 'a
  (** Introduces a continuation that needs to be eliminated exactly once. *)

  val return : 'a t -> 'a -> unit
  (** Eliminates the continuation by returning the given value to it. *)

  val raise : 'a t -> exn -> unit
  (** Eliminates the continuation by raising the given exception on it. *)
end
