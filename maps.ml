open Base

module type GENERATOR = sig
  type key
  type value
  val key_gen : key Crowbar.gen
  val val_gen : value Crowbar.gen
  val sexp_of_key: key -> Sexp.t
  val sexp_of_value : value -> Sexp.t
  val key_transform : key -> key
  val value_transform : value -> value
end

module Map_tester
    (KeyOrder: Shims.Comparably_buildable)
    (ValueOrder: Shims.Comparably_buildable)
    (G: GENERATOR with
      type key = KeyOrder.t and
      type value = ValueOrder.t
    ) = struct

  module KeyComparison = Comparable.Make_using_comparator(KeyOrder)
  module ValueComparison = Comparable.Make_using_comparator(ValueOrder)

  let pair : (G.key * G.value) Crowbar.gen
    = Crowbar.(map [G.key_gen; G.val_gen] (fun x y -> x, y))

  let sexp_of_map = Map.sexp_of_m__t
    (module struct type t = G.key let sexp_of_t = G.sexp_of_key end) G.sexp_of_value

  let pp_map fmt m =
    Sexp.pp fmt (sexp_of_map m)

  let largest val1 val2 =
    match ValueComparison.compare val1 val2 with
    | x when x < 0 -> val2
    | 0 -> val2
    | _ -> val1

  let map_eq =
    Crowbar.check_eq
      ~eq:(Map.equal (fun x y -> 0 = ValueComparison.compare x y))
      ~cmp:(Map.compare_direct ValueComparison.compare)
      ~pp:pp_map

  let disjunction =
    Map.merge ~f:(fun ~key:_ -> function
        | `Left v | `Right v -> Some v
        | `Both _ -> None)

  let rec map_gen = lazy (
    Crowbar.(choose [
        const @@ Map.empty @@ (module KeyOrder);
        map [G.key_gen; G.val_gen] (fun k v ->
            Map.singleton (module KeyOrder) k v);
        (* n.b. we don't use `of_alist` here on purpose -- we want to exercise the code path
           that adds individual items *)
        map [list pair] (fun items ->
            List.fold_left ~f:(fun m (key, data) -> Map.set m ~key ~data)
              ~init:(Map.empty (module KeyOrder))
              items);
        (* exercise both merge and merge_skewed *)
        map [(unlazy map_gen); (unlazy map_gen)] @@
          Map.merge_skewed ~combine:(fun ~key:_ val1 val2 -> largest val1 val2);
        map [(unlazy map_gen); (unlazy map_gen)] @@
          Map.merge ~f:(fun ~key:_ -> function | `Left v | `Right v -> Some v
                                                | `Both (v1, v2) -> Some (largest v1 v2));
        map [(unlazy map_gen); G.key_gen] (fun m k -> Map.remove m k);
        map [(unlazy map_gen); pair] (fun m (key, data) -> Map.set m ~key ~data);

        map [(unlazy map_gen); (unlazy map_gen)] disjunction; (* Map.merge *)
        (* unclear to me why it's worth retaining this -- generate a list of pairs
           and generate a new map with only the items present in both the previous map
           and the list; this will generate an empty map almost all of the time? *)
        map [(unlazy map_gen); list pair] (fun map l ->
            Map.filteri ~f:(fun ~key ~data ->
                match List.Assoc.find l ~equal:KeyComparison.equal key with
                | None -> false
                | Some v -> 0 = ValueComparison.compare data v
              ) map);
        (* this will do the same thing as above, just exercising partition instead *)
        (* partition is cool in Base because you can specify new value parameters for the partitioned maps *)
        (* that's not relevant to what we're doing here, although thinking about how we'd meaningfully
           exercise it is... too much for now *)
        map [(unlazy map_gen); list pair] (fun map l ->
             snd @@ Map.partition_mapi ~f:(fun ~key ~data ->
                match List.Assoc.find l ~equal:KeyComparison.equal key with
                | None -> `Fst data
                | Some v when 0 = ValueComparison.compare data v -> `Snd v
                | Some v -> `Fst v
              ) map);
        map [(unlazy map_gen); G.key_gen] (fun m k ->
            (* we could test whether this is equivalent to map.remove k m *)
            let l, _, r = Map.split m k in
            disjunction r l);
        map [(unlazy map_gen)] (fun m -> Map.map ~f:G.value_transform m);
        map [(unlazy map_gen)] (fun m -> Map.mapi ~f:(fun ~key:_ ~data -> G.value_transform data) m);
      ])
  )

  let lazy map_gen = map_gen

  let check_bounds map =
    match Map.min_elt map, Map.max_elt map with
    | Some (k1, _v1) , Some (k2, v2) when KeyComparison.compare k1 k2 = 0 ->
      (* this only makes sense for the singleton map *)
      map_eq map @@ Map.singleton (module KeyOrder) k1 v2
    | Some (min, _) , Some (max, _) -> KeyComparison.compare max min > 0 |> Crowbar.check
    | None, None -> map_eq map @@ Map.empty (module KeyOrder)
    | Some _, None | None, Some _ -> Crowbar.fail "max_elt and min_elt disagree on whether the map is empty"

  let check_invariants map = Crowbar.check @@ Map.invariants map

  let add_tests () =
    Crowbar.add_test ~name:"max_binding = min_binding implies all elements are equal"
      Crowbar.[map_gen] check_bounds;
    Crowbar.add_test ~name:"internal invariants checks pass"
      Crowbar.[map_gen] check_invariants;

end

module Make_generator(K: Shims.GENERABLE)(V: Shims.GENERABLE) = struct
  type key = K.t
  type value = V.t
  let sexp_of_key, sexp_of_value = K.sexp_of_t, V.sexp_of_t
  let key_gen, val_gen = K.gen, V.gen
  let key_transform, value_transform = K.transform, V.transform
end

module StringString = Make_generator(Shims.String)(Shims.String)
module IntString = Make_generator(Shims.Int)(Shims.String)
module FloatString = Make_generator(Shims.Float)(Shims.String)
module CharInt = Make_generator(Shims.Char)(Shims.Int)
module NativeintInt = Make_generator(Shims.Nativeint)(Shims.Int)
module UcharString = Make_generator(Shims.Uchar)(Shims.String)

module StringTester = Map_tester(String)(String)(StringString)
module IntStringTester = Map_tester(Int)(String)(IntString)
module FloatStringTester = Map_tester(Float)(String)(FloatString)
module CharIntTester = Map_tester(Char)(Int)(CharInt)
module NativeIntTester = Map_tester(Nativeint)(Int)(NativeintInt)
module UcharStringTester = Map_tester(Uchar)(String)(UcharString)
