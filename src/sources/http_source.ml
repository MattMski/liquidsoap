(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2008 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

exception Internal

(** Interface with stream decoders.
  * We can't use Decoder since it is designed for files, and estimates
  * the remaining number of frames. *)

let conf_http_source =
  Dtools.Conf.void ~p:(Configure.conf#plug "stream_decoding")
    "Stream decoding settings"
let conf_mime_types =
  Dtools.Conf.void ~p:(conf_http_source#plug "mime_types")
    "Mime-types used for guessing audio stream formats"
    ~comments:[
      "When a mime-type is available (e.g. with input.http), it can be used";
      "to guess which audio stream format is used.";
      "This section contains the listings used for that detection, which you";
      "might want to tweak if you encounter a new mime-type.";
      "If you feel that new mime-types should be permanently added, please";
      "contact the developpers."
    ]

type sink = {
  read : int -> string ;
  put : int -> float array array -> unit ;
  insert_metadata : Frame.metadata -> unit ;
  close : unit -> unit
}

(** Types for playlist handling *)
type playlist_mode =  Random | First | Randomize | Normal


let stream_decoders : (sink -> unit) Plug.plug =
  Plug.create ~doc:"Methods for decoding audio streams." "stream formats"

(** Utilities for reading icy metadata *)

let log = Dtools.Log.make ["readmeta"]
let read_metadata () = let old_chunk = ref "" in fun socket ->
  let size =
    let buf = " " in
    let s = Unix.read socket buf 0 1 in
      assert (s=1) ; (* NON *)
      int_of_char buf.[0]
  in
  let size = 16*size in
  let chunk =
    let buf = String.create size in
    let rec read pos =
      if pos=size then buf else
        let p = Unix.read socket buf pos (size-pos) in
          assert (p>0) ; (* NON *)
          read (pos+p)
    in
      read 0
  in
  let h = Hashtbl.create 10 in
  let rec parse s =
    try
      let mid = String.index s '=' in
      let close = String.index s ';' in
      let key = Configure.recode_tag (String.sub s 0 mid) in
      let value = Configure.recode_tag (String.sub s (mid+2) (close-mid-3)) in
      let key =
        match key with
          | "StreamTitle" -> "title"
          | "StreamUrl" -> "url"
          | _ -> key
      in
        Hashtbl.add h key value ;
        parse (String.sub s (close+1) ((String.length s)-close-1))
    with _ -> ()
  in
    if chunk = "" then begin
      (* log#f 4 "Empty chunk!" ; *)
      None
    end else if chunk = !old_chunk then begin
      (* log#f 4 "Redundant chunk (%S)!" chunk ; *)
      None
    end else begin
      old_chunk := chunk ;
      parse chunk ;
      Some h
    end

let read_line socket =
  let ans = ref "" in
  let c = String.create 1 in
    assert (Unix.read socket c 0 1 = 1); (* NON *)
    while c <> "\n" do
      ans := !ans ^ c;
      assert (Unix.read socket c 0 1 = 1); (* NON *)
    done;
    String.sub !ans 0 (String.length !ans - 1)

let read_chunk socket =
  let n = read_line socket in
  let n = Scanf.sscanf n "%x" (fun n -> n) in
  let ans = ref "" in
    while String.length !ans <> n do
      let buf = String.create (n - String.length !ans) in
      let r = Unix.read socket buf 0 (n - String.length !ans) in
        ans := !ans ^ (String.sub buf 0 r)
    done;
    !ans

let read_stream socket chunked metaint insert_metadata =
  let read_metadata = read_metadata () in
  let chunkbuf = ref "" in
  let read buf offs len =
    if chunked then
      (
        if String.length !chunkbuf = 0 then chunkbuf := read_chunk socket;
        let n = min len (String.length !chunkbuf) in
          String.blit !chunkbuf 0 buf offs n;
          chunkbuf := String.sub !chunkbuf n (String.length !chunkbuf - n);
          n
      )
    else
      Unix.read socket buf 0 len
  in
    match metaint with
      | None ->
          fun len ->
            let b = String.create len in
            let r = read b 0 len in
              if r < 0 then "" else String.sub b 0 r
      | Some metaint ->
          let readcnt = ref 0 in
            fun len ->
              let len = min len (metaint - !readcnt) in
              let b = String.create len in
              let r = read b 0 len in
                if r < 0 then "" else begin
                  readcnt := !readcnt + r;
                  if !readcnt = metaint then begin
                    readcnt := 0;
                    match read_metadata socket with
                      | Some m -> insert_metadata m
                      | None -> ()
                  end ;
                  String.sub b 0 r
                end

(** Generic http input *)

let url_expr = Str.regexp "^http://\\([^/]+\\)\\(/.*\\)?$"
let host_expr = Str.regexp "^\\([^:]+\\):\\([0-9]+\\)$"
let auth_split_expr = Str.regexp "^\\([^@]+\\)@\\(.+\\)$"

let parse_url url =
  let host,mount =
    if Str.string_match url_expr url 0 then
      (Str.matched_group 1 url),
      (try Str.matched_group 2 url with Not_found -> "/")
    else
      failwith (Printf.sprintf "Invalid URL %S!" url)
  in
  let auth,host =
    if Str.string_match auth_split_expr host 0 then
      (Str.matched_group 1 host),
      (Str.matched_group 2 host)
    else
      "",host
  in
    if Str.string_match host_expr host 0 then
      (Str.matched_group 1 host),
      (int_of_string (Str.matched_group 2 host)),
      mount,
      auth
    else
      host,80,mount,auth

module Generator = Float_pcm.Generator
module Generated = Generated.From_Float_pcm_Generator

(* Used to handle redirections. *)
exception Redirection of string

class http ~playlist_mode ~poll_delay ~timeout ~track_on_meta ?(force_mime=None)
           ~feed_delay ~bind_address ~autostart ~bufferize ~max ~debug 
           ~user_agent url =
  let abg_max_len =
    Fmt.samples_of_seconds (Pervasives.max max bufferize)
  in
object (self)
  inherit Source.source
  inherit Generated.source
            (Generator.create ())
            ~empty_on_abort:false ~bufferize

  method stype = Source.Fallible

  (** The poll_should_stop says that the current polling thread should stop,
    * because #sleep was called. The subsequent #wake_up call will wake for the
    * thread to set poll_should_stop to false again and exit.
    * The condition/lock devices are only useful for avoiding an active
    * wait in #wake_up, because the race conditions are completely harmless. *)
  val mutable poll_should_stop = false
  val polling_lock = Mutex.create ()
  val polling_cond = Condition.create ()

  val mutable connected = false
  val mutable relaying = autostart
  val mutable playlist_mode = playlist_mode

  (* Insert metadata *)
  method insert_metadata m =
    self#log#f 3 "New metadata chunk \"%s -- %s\""
                (try Hashtbl.find m "artist" with _ -> "?")
                (try Hashtbl.find m "title" with _ -> "?") ;
    Generator.add_metadata abg m ;
    if track_on_meta then Generator.add_break abg ;

  (* Feed the buffer generator *)
  method put sample_freq data =
    if not relaying then failwith "relaying stopped" ;
    Mutex.lock lock ;
    (* Drop data when buffer is full. This is the only way
     * to make it work with switches, when input.http is not
     * pulled for some time. *)
    if Generator.length abg >= abg_max_len then
      begin
        if feed_delay > 0. then
          begin
            Mutex.unlock lock ;
            Thread.delay feed_delay ;
            Mutex.lock lock
          end ;
        if Generator.length abg >= abg_max_len then
          Generator.remove abg (Generator.length abg - abg_max_len)
      end;
    Generator.feed abg ~sample_freq data ;
    Mutex.unlock lock

  method feeding ?(newstream=true) dec socket chunked metaint =
    connected <- true ;
    let close () = Http.disconnect socket in
    let read = read_stream socket chunked metaint self#insert_metadata in
    let sink =
      { put = self#put ; read = read ;
        insert_metadata = self#insert_metadata ; close = close }
    in
      try
       (* Starting decoding: adding a break here *)
       Generator.add_break abg ;
       dec sink
      with
        | e ->
            begin
              (* Feeding has stopped: adding a break here *)
              Generator.add_break abg ;
              self#log#f 2 "Feeding stopped: %s" (Printexc.to_string e);
              if debug then raise e
            end

  method connect = self#private_connect ~encode:true

  (* Called when there's no decoding process, in order to create one. *)
  method private_connect ?(encode=true) url =
    let url =
      if encode then
        Http.http_encode url
      else
        url
    in
    let host,port,mount,auth = parse_url url in
    let req =
      Printf.sprintf
        "GET %s HTTP/1.0\r\nHost: %s:%d\r\n"
        mount host port
    in
    let auth =
      match auth with
        | "" -> ""
        | _ -> "Authorization: Basic " ^ (Utils.encode64 auth) ^ "\r\n"
    in
    let request =
      Printf.sprintf
        "%sUser-Agent: %s\r\n%sIcy-MetaData:1\r\n\r\n"
        req user_agent auth
    in
      self#log#f 4 "Connecting to <http://%s:%d%s>..." host port mount ;
      try
        let socket =
          Http.connect ~bind_address ~timeout:(Some timeout) host port
        in
          try
            let (_, status, status_msg), fields = Http.request socket request in
            let content_type =
              match force_mime with
                | Some s -> s
                | None ->
              let content_type =
                try List.assoc "content-type" fields with Not_found -> "unknown"
              in
              (* Remove modifiers from content type. *)
                try
                  let sub = Pcre.exec ~pat:"^([^;]+);.*$" content_type in
                    Pcre.get_substring sub 1
                with
                | Not_found -> content_type
            in
            let metaint =
              try
                Some (int_of_string (List.assoc "icy-metaint" fields))
              with _ -> None
            in
            let chunked =
              try
                List.assoc "transfer-encoding" fields = "chunked"
              with _ -> false
            in
              if
                status = 301 || status = 302 || status = 303 || status = 307
              then begin
                let location =
                  try
                    List.assoc "location" fields
                  with
                    | Not_found -> raise Internal
                in
                  self#log#f 4 "Redirected to %s" location;
                  raise (Redirection location)
              end ;
              if status <> 200 then begin
                self#log#f 4 "Could not get file: %s" status_msg;
                raise Internal
              end ;
              let play_track (m,uri) =
                let metas = Hashtbl.create 2 in
                  List.iter (fun (a,b) -> Hashtbl.add metas a b) m;
                  self#insert_metadata metas;
                  self#private_connect uri
              in
              let randomize playlist =
                let aplay = Array.of_list playlist in
                  Utils.randomize aplay;
                  Array.to_list aplay
              in
              let playlist_process playlist =
                try
                  match playlist_mode with
                    | Random ->  play_track (List.hd (randomize playlist))
                    | First -> play_track (List.hd playlist)
                    | Randomize -> List.iter play_track (randomize playlist)
                    | Normal -> List.iter play_track playlist
                with
                  | Failure hd -> raise Not_found
              in
              let test_playlist parser =
                let content = Http.read socket None in
                let playlist = parser content in
                  match playlist with
                    | [] -> raise Not_found
                    | _ -> () ;
                           playlist_process playlist
              in
                try
                  self#log#f 4
                    "Trying playlist parser for mime %s" content_type ;
                  match Playlist_parser.parsers#get content_type with
                    | None -> raise Not_found
                    | Some plugin ->
                        test_playlist plugin.Playlist_parser.parser
                with
                  | Not_found ->
                      (* Trying playlist auto parsing in case
                       * of content type text/plain *)
                      if content_type = "text/plain" then
                        begin
                          try
                            test_playlist
                              (fun x -> snd (Playlist_parser.search_valid x))
                          with
                            | Not_found -> ()
                        end;
                      self#log#f 4 "Content-type \"%s\"." content_type ;
                      if chunked then self#log#f 4 "Chunked HTTP/1.1 transfer" ;
                      let dec =
                        match
                          stream_decoders#get content_type
                        with
                          | Some d -> d
                          | None -> failwith "Unknown format!"
                      in
                        self#log#f 3 "Decoding..." ;
                        self#feeding dec socket chunked metaint
          with
            | e ->
                Http.disconnect socket;
                raise e
      with
        | Redirection location ->
            self#private_connect ~encode:false location
        | Http.Error e ->
            self#log#f 4 "Connection failed: %s!" (Http.string_of_error e)
        | e ->
            self#log#f 4 "Connection failed: %s" (Printexc.to_string e)

  (* Take care of (re)starting the decoding *)
  method poll =
    (* Try to read the stream *)
    if relaying then self#connect url ;
    if poll_should_stop then begin
      poll_should_stop <- false ;
      Condition.signal polling_cond
    end else begin
      (* TODO Use Duppy instead of a separate thread ? *)
      Thread.delay poll_delay ;
      self#poll
    end

  val mutable ns = []

  method wake_up _ =
    (* Wait for the old polling thread to return, then create a new one. *)
    Tutils.wait polling_cond polling_lock (fun () -> not poll_should_stop) ;
    ignore (Tutils.create (fun () -> self#poll) () "http polling") ;
    if ns = [] then
      ns <- Server.register [self#id] "input.http" ;
    self#set_id (Server.to_string ns) ;
    Server.add ~ns "start" ~usage:"start" ~descr:"Start the source, if needed."
       (fun _ -> relaying <- true ; "Done") ;
    Server.add ~ns "stop" ~usage:"stop" ~descr:"Stop the source if streaming."
       (fun _ -> relaying <- false ; "Done")

  method sleep = poll_should_stop <- true

end

let () =
    Lang.add_operator "input.http"
      ~category:Lang.Input
      ~descr:"Forwards the given http stream. The relay can be \
              paused/resumed using the start/stop telnet commands."
      [ "autostart", Lang.bool_t, Some (Lang.bool true),
        Some "Initially start relaying or not." ;

        "bind_address", Lang.string_t, Some (Lang.string ""),
        Some "Address to bind on the local machine. \
              This option can be useful if \
              your machine is bound to multiple IPs. \
              Empty means no bind address." ;

        "buffer", Lang.float_t, Some (Lang.float 2.),
        Some "Duration of the pre-buffered data." ;

        "timeout", Lang.float_t, Some (Lang.float 10.),
        Some "Timeout for http connection." ;

        "new_track_on_metadata", Lang.bool_t, Some (Lang.bool true),
        Some "Treat new metadata as new track." ;

        "force_mime", Lang.string_t, Some (Lang.string ""),
        Some "Force mime data type. Not used if empty." ;

        "playlist_mode", Lang.string_t, Some (Lang.string "normal"),
        Some "Valid modes are \"normal\", \"random\", \"randomize\" \
              and \"first\". The first ones have the same meaning as for \
              the mode parameter of the playlist operator. The last one \
              discards all entries but the first one." ;

        "poll_delay", Lang.float_t, Some (Lang.float 2.),
        Some "Polling delay." ;

        "max", Lang.float_t, Some (Lang.float 10.),
        Some "Maximum duration of the buffered data." ;

        "debug", Lang.bool_t, Some (Lang.bool false),
        Some "Run in debugging mode by not catching some exceptions." ;

        "feed_delay", Lang.float_t, Some (Lang.float (-1.)),
        Some "Feeding delay to apply when the buffer is full. \
              This setting can lead to disconnections when the \
              source is not pulled. If positive, the feeding thread \
              will wait for the given delay before dropping data when \
              the buffer is full." ;

       "user_agent", Lang.string_t, 
        Some (Lang.string 
            (Printf.sprintf "liquidsoap/%s (%s; ocaml %s)"
                Configure.version Sys.os_type Sys.ocaml_version)),
        Some "User agent." ; 

        "", Lang.string_t, None,
        Some "URL of an http stream (default port is 80)." ]
      (fun p ->
         let playlist_mode =
           let s = List.assoc "playlist_mode" p in
             match Lang.to_string s with
               | "random" -> Random
               | "first" -> First
               | "randomize" -> Randomize
               | "normal" -> Normal
               | _ ->
                   raise
                     (Lang.Invalid_value
                        (s,
                         "valid values are 'random', 'randomize', \
                          'normal' and 'first'"))
         in
         let url = Lang.to_string (List.assoc "" p) in
         let autostart = Lang.to_bool (List.assoc "autostart" p) in
         let bind_address = Lang.to_string (List.assoc "bind_address" p) in
         let user_agent = Lang.to_string (List.assoc "user_agent" p) in
         let track_on_meta =
           Lang.to_bool (List.assoc "new_track_on_metadata" p)
         in
         let debug = Lang.to_bool (List.assoc "debug" p) in
         let bind_address =
           match bind_address with
             | "" -> None
             | s -> Some s
         in
         let force_mime =
           match Lang.to_string (List.assoc "force_mime" p) with
             | "" -> None
             | s  -> Some s
         in
         let bufferize = Lang.to_float (List.assoc "buffer" p) in
         let timeout = Lang.to_float (List.assoc "timeout" p) in
         let max = Lang.to_float (List.assoc "max" p) in
         let poll_delay = Lang.to_float (List.assoc "poll_delay" p) in
         let feed_delay = Lang.to_float (List.assoc "feed_delay" p) in
           ((new http ~playlist_mode ~timeout ~autostart ~track_on_meta
                      ~force_mime ~feed_delay ~bind_address ~poll_delay
                      ~bufferize ~max ~debug ~user_agent url)
              :> Source.source))
