%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 13 Dec 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(xmpp_stream_pkix).

%% API
-export([authenticate/1, authenticate/2]).

-include("xmpp.hrl").
-include_lib("public_key/include/public_key.hrl").
-include("XmppAddr.hrl").

%%%===================================================================
%%% API
%%%===================================================================
-spec authenticate(xmpp_stream_in:state() | xmpp_stream_out:state())
      -> {ok, binary()} | {error, binary(), binary()}.
authenticate(State) ->
    authenticate(State, <<"">>).

-spec authenticate(xmpp_stream_in:state() | xmpp_stream_out:state(), binary())
      -> {ok, binary()} | {error, binary(), binary()}.
authenticate(#{xmlns := ?NS_SERVER, remote_server := Peer,
	       sockmod := SockMod, socket := Socket}, _Authzid) ->
    case SockMod:get_peer_certificate(Socket) of
	{ok, Cert} ->
	    case SockMod:get_verify_result(Socket) of
		0 ->
		    case ejabberd_idna:domain_utf8_to_ascii(Peer) of
			false ->
			    {error, <<"Cannot decode remote server name">>, Peer};
			AsciiPeer ->
			    case lists:any(
				   fun(D) -> match_domain(AsciiPeer, D) end,
				   get_cert_domains(Cert)) of
				true ->
				    {ok, Peer};
				false ->
				    {error, <<"Certificate host name mismatch">>, Peer}
			    end
		    end;
		VerifyRes ->
		    {error, fast_tls:get_cert_verify_string(VerifyRes, Cert), Peer}
	    end;
	{error, _Reason} ->
	    {error, <<"Cannot get peer certificate">>, Peer};
	error ->
	    {error, <<"Cannot get peer certificate">>, Peer}
    end;
authenticate(_State, _Authzid) ->
    %% TODO: client PKIX authentication
    {error, <<"Client certificate verification not implemented">>, <<"">>}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
get_cert_domains(Cert) ->
    TBSCert = Cert#'Certificate'.tbsCertificate,
    Subject = case TBSCert#'TBSCertificate'.subject of
		  {rdnSequence, Subj} -> lists:flatten(Subj);
		  _ -> []
	      end,
    Extensions = case TBSCert#'TBSCertificate'.extensions of
		     Exts when is_list(Exts) -> Exts;
		     _ -> []
		 end,
    lists:flatmap(
      fun(#'AttributeTypeAndValue'{type = ?'id-at-commonName',value = Val}) ->
	      case 'OTP-PUB-KEY':decode('X520CommonName', Val) of
		  {ok, {_, D1}} ->
		      D = if is_binary(D1) -> D1;
			     is_list(D1) -> list_to_binary(D1);
			     true -> error
			  end,
		      if D /= error ->
			      case jid:from_string(D) of
				  #jid{luser = <<"">>, lserver = LD,
				       lresource = <<"">>} ->
				      [LD];
				  _ -> []
			      end;
			 true -> []
		      end;
		  _ -> []
	      end;
	 (_) -> []
      end, Subject) ++
	lists:flatmap(
	  fun(#'Extension'{extnID = ?'id-ce-subjectAltName',
			   extnValue = Val}) ->
		  BVal = if is_list(Val) -> list_to_binary(Val);
			    true -> Val
			 end,
		  case 'OTP-PUB-KEY':decode('SubjectAltName', BVal) of
		      {ok, SANs} ->
			  lists:flatmap(
			    fun({otherName, #'AnotherName'{'type-id' = ?'id-on-xmppAddr',
							   value = XmppAddr}}) ->
				    case 'XmppAddr':decode('XmppAddr', XmppAddr) of
					{ok, D} when is_binary(D) ->
					    case jid:from_string(D) of
						#jid{luser = <<"">>,
						     lserver = LD,
						     lresource = <<"">>} ->
						    case ejabberd_idna:domain_utf8_to_ascii(LD) of
							false ->
							    [];
							PCLD ->
							    [PCLD]
						    end;
						_ -> []
					    end;
					_ -> []
				    end;
			       ({dNSName, D}) when is_list(D) ->
				    case jid:from_string(list_to_binary(D)) of
					#jid{luser = <<"">>,
					     lserver = LD,
					     lresource = <<"">>} ->
					    [LD];
					_ -> []
				    end;
			       (_) -> []
			    end, SANs);
		      _ -> []
		  end;
	     (_) -> []
	  end, Extensions).

match_domain(Domain, Domain) -> true;
match_domain(Domain, Pattern) ->
    DLabels = str:tokens(Domain, <<".">>),
    PLabels = str:tokens(Pattern, <<".">>),
    match_labels(DLabels, PLabels).

match_labels([], []) -> true;
match_labels([], [_ | _]) -> false;
match_labels([_ | _], []) -> false;
match_labels([DL | DLabels], [PL | PLabels]) ->
    case lists:all(fun (C) ->
			   $a =< C andalso C =< $z orelse
			     $0 =< C andalso C =< $9 orelse
			       C == $- orelse C == $*
		   end,
		   binary_to_list(PL))
	of
      true ->
	  Regexp = ejabberd_regexp:sh_to_awk(PL),
	  case ejabberd_regexp:run(DL, Regexp) of
	    match -> match_labels(DLabels, PLabels);
	    nomatch -> false
	  end;
      false -> false
    end.