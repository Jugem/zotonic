%% @author Marc Worrell <marc@worrell.nl>
%% @author Atilla Erdodi <atilla@maximonster.com>
%% @copyright 2010-2011 Maximonster Interactive Things
%% @doc Email server.  Queues, renders and sends e-mails.

%% Copyright 2010-2011 Maximonster Interactive Things
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(z_email_server).
-author("Atilla Erdodi <atilla@maximonster.com>").
-author("Marc Worrell <marc@worrell.nl>").
-behaviour(gen_server).

%% gen_server exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% interface functions
-export([
    start_link/0,
    is_bounce_email/1,
    bounced/1,
    generate_message_id/0,
    send/2,
    send/3
]).

-include_lib("zotonic.hrl").
-include_lib("stdlib/include/qlc.hrl").

% Maximum times we retry to send a message before we mark it as failed.
-define(MAX_RETRY, 7).
% The time in minutes how long sent email should be kept in the queue.
-define(DELETE_AFTER, 240).
% Timeout value for the connection of the spamassassin daemon
-define(SPAMD_TIMEOUT, 10000).

-record(state, {smtp_relay, smtp_relay_opts, smtp_no_mx_lookups,
                smtp_verp_as_from, smtp_bcc, override, smtp_spamd_ip, smtp_spamd_port}).
-record(email_queue, {id, retry_on=inc_timestamp(now(), 10), retry=0, 
                      recipient, email, created=now(), sent, 
                      pickled_context}).

%%====================================================================
%% API
%%====================================================================
%% @spec start_link() -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
start_link() ->
    start_link([]).
%% @spec start_link(Args::list()) -> {ok,Pid} | ignore | {error,Error}
%% @doc Starts the server
start_link(Args) when is_list(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).


%% @doc Check if the received e-mail address is a bounce address
is_bounce_email(<<"noreply+",_/binary>>) -> true;
is_bounce_email("noreply+"++_) -> true;
is_bounce_email(_) -> false.

%% @doc Handle a bounce
bounced(NoReplyEmail) ->
    gen_server:cast(?MODULE, {bounced, NoReplyEmail}).
    

%% @doc Generate a new message id
generate_message_id() ->
    z_convert:to_binary(z_string:to_lower(z_ids:id(20))).


%% @doc Send an email
send(#email{} = Email, Context) ->
    send(generate_message_id(), Email, Context).

%% @doc Send an email using a predefined unique id.
send(Id, #email{} = Email, Context) ->
    Id1 = z_convert:to_binary(Id),
    Context1 = z_context:depickle(z_context:pickle(Context)),
    gen_server:cast(?MODULE, {send, Id1, Email, Context1}),
    {ok, Id1}.


%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore               |
%%                     {stop, Reason}
%% @doc Initiates the server.
init(_Args) ->
    mnesia:create_table(email_queue,
                        [{attributes, record_info(fields, email_queue)}]),
    timer:send_interval(5000, poll),
    State = #state{},
    {ok, State}.
    

%% @spec handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% @doc Trap unknown calls
handle_call(Message, _From, State) ->
    {stop, {unknown_call, Message}, State}.

%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}

%% @doc Send an e-mail.
handle_cast({send, Id, #email{} = Email, Context}, State) ->
    State1 = update_config(State),
    case z_utils:is_empty(Email#email.to) of
        true -> nop;
        false -> send_email(Id, Email#email.to, Email, Context, State1)
    end,
    case z_utils:is_empty(Email#email.cc) of
        true -> nop;
        false -> send_email(<<Id/binary, "+cc">>, Email#email.cc, Email, Context, State1)
    end,
    case z_utils:is_empty(Email#email.bcc) of
        true -> nop;
        false -> send_email(<<Id/binary, "+bcc">>, Email#email.bcc, Email, Context, State1)
    end,
    {noreply, State1};

%%@ doc Handle a bounced email
handle_cast({bounced, BounceEmail}, State) ->
    % Fetch the MsgId from the bounce address
    [BounceLocalName|_] = binstr:split(z_convert:to_binary(BounceEmail), <<"@">>),
    <<"noreply+", MsgId/binary>> = BounceLocalName,

    % Find the original message in our database of recent sent e-mail
    TrFun = fun()-> 
                    [QEmail] = mnesia:read(email_queue, MsgId), 
                    mnesia:delete_object(QEmail),
                    {(QEmail#email_queue.email)#email.to, QEmail#email_queue.pickled_context}
            end,
    case mnesia:transaction(TrFun) of
        {atomic, {Recipient, PickledContext}} ->
            Context = z_context:depickle(PickledContext),
            z_notifier:first({email_bounced, MsgId, Recipient}, Context);
        _ ->
            % We got a bounce, but we don't have the message anymore.
            % Custom bounce domains make this difficult to process
            ok
    end,
    {noreply, State};
%% @doc Trap unknown casts
handle_cast(Message, State) ->
    {stop, {unknown_cast, Message}, State}.

%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @doc Poll the database queue for any retrys.
handle_info(poll, State) ->
    State1 = poll_queued(State),
    z_utils:flush_message(poll),
    {noreply, State1};

%% @doc Handling all non call/cast messages
handle_info(_Info, State) ->
    {noreply, State}.

%% @spec terminate(Reason, State) -> void()
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
terminate(_Reason, _State) ->
    ok.

%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @doc Convert process state when code is changed
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% support functions
%%====================================================================

%% @doc Refetch the emailer configuration so that we adapt to any config changes.
update_config(State) ->
    SmtpRelay = z_config:get(smtp_relay),
    SmtpRelayOpts = 
        case SmtpRelay of 
            true ->
                [{relay, z_config:get(smtp_host)},
                 {port, z_config:get(smtp_port)},
                 {ssl, z_config:get(smtp_ssl)}]
                ++ case {z_config:get(smtp_username),
                         z_config:get(smtp_password)} of
                        {undefined, undefined} ->
                            [];
                        {User, Pass} ->
                            [{auth, always},
                             {username, User},
                             {password, Pass}]
                   end;
            false ->
                []
        end,
    SmtpNoMxLookups = z_config:get(smtp_no_mx_lookups),
    SmtpVerpAsFrom = z_config:get(smtp_verp_as_from),
    SmtpBcc = z_config:get(smtp_bcc),
    Override = z_config:get(email_override),
    SmtpSpamdIp = z_config:get(smtp_spamd_ip),
    SmtpSpamdPort = z_config:get(smtp_spamd_port),
    State#state{smtp_relay=SmtpRelay,
                smtp_relay_opts=SmtpRelayOpts,
                smtp_no_mx_lookups=SmtpNoMxLookups,
                smtp_verp_as_from=SmtpVerpAsFrom,
                smtp_bcc=SmtpBcc,
                override=Override,
                smtp_spamd_ip=SmtpSpamdIp,
                smtp_spamd_port=SmtpSpamdPort}.


% E-mail domain, depends on the smtp domain of the sending site

bounce_email(MessageId, Context) ->
    "noreply+"++z_convert:to_list(MessageId)++[$@ | bounce_domain(Context)].

reply_email(MessageId, Context) ->
    "reply+"++z_convert:to_list(MessageId)++[$@ | email_domain(Context)].

% Ensure that the sites's domain is attached to the email address.
ensure_domain(Email, Context) when is_list(Email) ->
    case lists:member($@, Email) of
        true -> Email;
        false -> Email ++ [$@|email_domain(Context)]
    end;
ensure_domain(Email, Context) ->
    ensure_domain(z_convert:to_list(Email), Context).


% Bounces can be forced to a different e-mail server altogether
bounce_domain(Context) ->
    case z_config:get('smtp_bounce_domain') of
        undefined -> email_domain(Context);
        BounceDomain -> BounceDomain
    end.

% The email domain depends on the site sending the e-mail
email_domain(Context) ->
    case m_config:get_value(site, smtphost, Context) of
        undefined -> z_context:hostname(Context);
        SmtpHost -> z_convert:to_list(SmtpHost)
    end.

% The 'From' is either the message id (and bounce domain) or the set from.
get_email_from(EmailFrom, VERP, State, Context) ->
    From = case EmailFrom of
        L when L =:= [] orelse L =:= undefined orelse L =:= <<>> -> 
            get_email_from(Context);
        _ -> EmailFrom
    end,
    case State#state.smtp_verp_as_from of
        true ->
            {FromName, _FromEmail} = z_email:split_name_email(From),
            string:strip(FromName ++ " " ++ VERP);
        _ ->
            {FromName, FromEmail} = z_email:split_name_email(From),
            case FromEmail of
                [] -> string:strip(FromName ++ " <" ++ get_email_from(Context) ++ ">");
                _ -> From
            end
    end.

% When the 'From' is not the VERP then the 'From' is derived from the site
get_email_from(Context) ->
    %% Let the default be overruled by the config setting
    case m_config:get_value(site, email_from, Context) of
        undefined -> "noreply@" ++ email_domain(Context);
        EmailFrom -> z_convert:to_list(EmailFrom)
    end.



%% =========================
%% SENDING related functions
%% =========================

% Send an email
send_email(Id, Recipient, Email, Context, State) ->
    QEmail = #email_queue{id=Id,
                          recipient=Recipient,
                          email=Email,
                          pickled_context=z_context:pickle(Context)},
    QEmailTransFun = fun() -> mnesia:write(QEmail) end,
    {atomic, ok} = mnesia:transaction(QEmailTransFun),        
    case Email#email.queue of
        false -> spawn_send(Id, Recipient, Email, Context, State);
        true -> ok
    end.


spawn_send(Id, Recipient, Email, Context, State) ->
    F = fun() ->
            VERP = "<"++bounce_email(Id, Context)++">",

            From = get_email_from(Email#email.from, VERP, State, Context),
            Recipient1 = check_override(Recipient, State),
            Recipient2 = string:strip(z_string:line(binary_to_list(z_convert:to_binary(Recipient1)))),
            {_RcptName, RecipientEmail} = z_email:split_name_email(Recipient2),
            [_RcptLocalName, RecipientDomain] = string:tokens(RecipientEmail, "@"),

            EncodedMail = encode_email(Id, Email, VERP, From, Context),
            
            SmtpOpts = 
                case State#state.smtp_relay of
                    true ->
                        [{no_mx_lookups, State#state.smtp_no_mx_lookups} |
                         State#state.smtp_relay_opts];
                    false ->
                        [{no_mx_lookups, State#state.smtp_no_mx_lookups},
                         {relay, RecipientDomain}]
                end,

            %% use the unique id as 'envelope sender' (VERP)
            case gen_smtp_client:send_blocking({VERP, [RecipientEmail], EncodedMail}, SmtpOpts) of
                {error, retries_exceeded, {temporary_failure, _LastRelay, _Bin}} ->
                    %% do nothing, it will retry later
                    ok;
                {error, no_more_hosts, _ErrorDetails} ->
                    %% delete email from the queue and notify the system
                    delete_emailq(Id),
                    ?DEBUG(_ErrorDetails),
                    z_notifier:first({email_failed, Id, Recipient}, Context);
                {error, Reason} ->
                    %% delete email from the queue and notify the system
                    delete_emailq(Id),
                    z_notifier:first({email_failed, Id, Recipient}, Context),
                    io:format("Invalid SMTP options: ~p\n", [Reason]);
                Recepit when is_binary(Recepit) ->
                    %% email accepted by relay
                    mark_sent(Id),
                    %% async send a copy for debugging if necessary
                    case z_utils:is_empty(State#state.smtp_bcc) of
                        true -> 
                            ok;
                        false -> 
                            catch gen_smtp_client:send({VERP, [State#state.smtp_bcc], EncodedMail}, SmtpOpts)
                    end,
                    %% check SpamAssassin spamscore
                    case {State#state.smtp_spamd_ip, State#state.smtp_spamd_port} of
                        {Addr, _Port} when Addr =:= [] orelse Addr =:= undefined ->
                            ok;
                        {Addr, Port} ->
                            SpamStatus = spamcheck(EncodedMail, Addr, Port),
                            z_notifier:first({email_spamstatus, Id, SpamStatus}, Context)
                    end
                            
            end
        end,
    spawn(F).


encode_email(_Id, #email{raw=Raw}, _VERP, _From, _Context) when is_list(Raw); is_binary(Raw) ->
    z_convert:to_binary([
        "X-Mailer: Zotonic ", ?ZOTONIC_VERSION, " (http://zotonic.com)\r\n", 
        Raw
    ]);
encode_email(Id, #email{body=undefined} = Email, VERP, From, Context) ->
    %% Optionally render the text and html body
    Vars = [{email_to, Email#email.to}, {email_from, From} | Email#email.vars],
    Text = optional_render(Email#email.text, Email#email.text_tpl, Vars, Context),
    Html = optional_render(Email#email.html, Email#email.html_tpl, Vars, Context),

    %% Fetch the subject from the title of the HTML part or from the Email record
    Subject = case {Html, Email#email.subject} of
                      {[], undefined} -> [];
                      {[], Sub} -> Sub;
                      {_Html, undefined} ->
                          {match, [_, {Start,Len}|_]} = re:run(Html, "<title>(.*)</title>", [dotall, caseless]),
                          string:strip(z_string:line(lists:sublist(Html, Start+1, Len)))
                  end,
    Headers = [{"From", From},
               {"To", z_convert:to_list(Email#email.to)},
               {"Subject", z_convert:to_flatlist(Subject)},
    {"Date", date(Context)},
               {"MIME-Version", "1.0"},
               {"Message-ID", VERP},
               {"X-Mailer", "Zotonic " ++ ?ZOTONIC_VERSION ++ " (http://zotonic.com)"}],
    Headers2 = add_reply_to(Id, Email, add_cc(Email, Headers), Context),
    build_and_encode_mail(Headers2, Text, Html, Context);
encode_email(Id, #email{body=Body} = Email, VERP, From, Context) when is_tuple(Body) ->
    Headers = [{<<"From">>, From},
               {<<"To">>, Email#email.to},
               {<<"Message-ID">>, VERP},
               {<<"X-Mailer">>, "Zotonic " ++ ?ZOTONIC_VERSION ++ " (http://zotonic.com)"}
                | Email#email.headers ],
    Headers2 = add_reply_to(Id, Email, add_cc(Email, Headers), Context),
    {BodyType, BodySubtype, BodyHeaders, BodyParams, BodyParts} = Body,
    MailHeaders = [
        {z_convert:to_binary(H), z_convert:to_binary(V)} || {H,V} <- (Headers2 ++ BodyHeaders)
    ],
    mimemail:encode({BodyType, BodySubtype, MailHeaders, BodyParams, BodyParts});
encode_email(Id, #email{body=Body} = Email, VERP, From, Context) when is_list(Body); is_binary(Body) ->
    Headers = [{"From", From},
               {"To", z_convert:to_list(Email#email.to)},
               {"Message-ID", VERP},
               {"X-Mailer", "Zotonic " ++ ?ZOTONIC_VERSION ++ " (http://zotonic.com)"}
                | Email#email.headers ],
    Headers2 = add_reply_to(Id, Email, add_cc(Email, Headers), Context),
    iolist_to_binary([ encode_headers(Headers2), "\r\n\r\n", Body ]).

    date(Context) ->
        z_convert:to_list(erlydtl_dateformat:format("r", z_context:set_language(en, Context))).


    add_cc(#email{cc=undefined}, Headers) ->
        Headers;
    add_cc(#email{cc=[]}, Headers) ->
        Headers;
    add_cc(#email{cc=Cc}, Headers) ->
        Headers ++ [{"Cc", Cc}].

    add_reply_to(_Id, #email{reply_to=undefined}, Headers, _Context) ->
        Headers;
    add_reply_to(_Id, #email{reply_to = <<>>}, Headers, _Context) ->
        [{"Reply-To", "<>"} | Headers];
    add_reply_to(Id, #email{reply_to=message_id}, Headers, Context) ->
        [{"Reply-To", reply_email(Id, Context)} | Headers];
    add_reply_to(_Id, #email{reply_to=ReplyTo}, Headers, Context) ->
        {Name, Email} = z_email:split_name_email(ReplyTo),
        ReplyTo1 = string:strip(Name ++ " <" ++ ensure_domain(Email, Context) ++ ">"),
        [{"Reply-To", ReplyTo1} | Headers].


build_and_encode_mail(Headers, Text, Html, Context) ->
    Headers1 = [
        {z_convert:to_binary(H), z_convert:to_binary(V)} || {H,V} <- Headers
    ],
    Parts = case z_utils:is_empty(Text) of
        true ->
            case z_utils:is_empty(Html) of
                true -> 
                    [];
                false -> 
                    [{<<"text">>, <<"plain">>, [], [], 
                     expand_cr(z_convert:to_binary(z_markdown:to_markdown(Html, [no_html])))}]
            end;
        false -> 
            [{<<"text">>, <<"plain">>, [], [], 
             expand_cr(z_convert:to_binary(Text))}]
    end,
    Parts1 = case z_utils:is_empty(Html) of
        true -> 
            Parts;
        false -> 
            z_email_embed:embed_images(Parts ++ [{<<"text">>, <<"html">>, [], [], z_convert:to_binary(Html)}], Context)
    end,
    mimemail:encode({<<"multipart">>, <<"alternative">>, Headers1, [], Parts1}).


% Make sure that loose \n characters are expanded to \r\n
expand_cr(B) -> expand_cr(B, <<>>).

    expand_cr(<<>>, Acc) -> Acc;
    expand_cr(<<13, 10, R/binary>>, Acc) -> expand_cr(R, <<Acc/binary, 13, 10>>);
    expand_cr(<<10, R/binary>>, Acc) -> expand_cr(R, <<Acc/binary, 13, 10>>);
    expand_cr(<<13, R/binary>>, Acc) -> expand_cr(R, <<Acc/binary, 13, 10>>);
    expand_cr(<<C, R/binary>>, Acc) -> expand_cr(R, <<Acc/binary, C>>).


spamcheck(EncodedMail, SpamDServer, SpamDPort) ->
    Email = binary_to_list(EncodedMail),
    
    {ok, Socket} = gen_tcp:connect(SpamDServer, SpamDPort, [list]),
    gen_tcp:send(Socket, "HEADERS SPAMC/1.2\r\n"),
    ContLen = integer_to_list(length(Email) + 2),
    gen_tcp:send(Socket, "Content-length: " ++ ContLen ++ "\r\n"),
    gen_tcp:send(Socket, "User: spamd\r\n"),
    gen_tcp:send(Socket, "\r\n"),
    gen_tcp:send(Socket, Email),
    gen_tcp:send(Socket, "\r\n"),
    
    Response = recv_spamd(Socket, []),
    gen_tcp:close(Socket),
    
    ParsedRes = parse_spamd_headers(Response),
    SpamStatus = proplists:get_value("X-Spam-Status", ParsedRes),
    IsSpam = case SpamStatus of
        "Yes, " ++ RestStatus -> true;
        "No, " ++ RestStatus -> false
    end,
    Results = [{is_spam, IsSpam} | [{list_to_atom(Field), Value} || [Field, Value] <- [string:tokens(Field, "=") || Field <- string:tokens(RestStatus, " ")]]],
    
    Results.

parse_spamd_headers(L) ->
    parse_spamd_headers(L, [], undefined).
parse_spamd_headers([], Acc, _) ->
    lists:reverse(Acc);
parse_spamd_headers(L, Acc, undefined) ->
    {FieldName, Rest} = parse_spamd_field_name(L, []),
    parse_spamd_headers(Rest, Acc, FieldName);
parse_spamd_headers(L, Acc, FieldName) ->
    {FieldValue, Rest} = parse_spamd_field_value(L, [], empty),
    parse_spamd_headers(Rest, [{FieldName, FieldValue} | Acc], undefined).


parse_spamd_field_name([], _) -> % ignore trailing characters
    {[], []};
parse_spamd_field_name([$: | Rest], Acc) ->
    {string:strip(lists:reverse(Acc)), Rest};
parse_spamd_field_name([C | Rest], Acc) ->
    parse_spamd_field_name(Rest, [C | Acc]).

parse_spamd_field_value([$\r | [$\n | Rest]], Acc, rn) -> % omit multiple \r\n-s
    parse_spamd_field_value(Rest, Acc, rn);
parse_spamd_field_value([$\r | Rest], Acc, empty) -> % put \r to the stack
    parse_spamd_field_value(Rest, Acc, r);
parse_spamd_field_value([$\n | Rest], Acc, r) -> % put \n to the stack
    parse_spamd_field_value(Rest, Acc, rn);
parse_spamd_field_value([$\t | Rest], Acc, rn) -> % read-ahead rule for \t
    parse_spamd_field_value(Rest, Acc, empty); % omit tabulator characters
parse_spamd_field_value([C | Rest], Acc, r) -> % read-ahead rule for non \n chars after \r
    parse_spamd_field_value(Rest, [C | [$\r | Acc]], empty);
parse_spamd_field_value([C | Rest], Acc, empty) ->
    parse_spamd_field_value(Rest, [C | Acc], empty);
parse_spamd_field_value(Rest, Acc, rn) -> % terminate
    {string:strip(lists:reverse(Acc)), Rest}.
    
recv_spamd(Socket, Res) ->
    receive
        {tcp, Socket, "SPAMD/1.1 0 EX_OK\r\n" ++ Data} ->
            recv_spamd(Socket, Res ++ Data);
        {tcp, Socket, Data} ->
            recv_spamd(Socket, Res ++ Data);
        {tcp_closed, Socket} ->
            Res
    after ?SPAMD_TIMEOUT ->
            io:format("spamassassin timeout~n"),
            Res
    end.
   
check_override(EmailAddr, _) when EmailAddr == undefined; EmailAddr == []; EmailAddr == <<>> ->
    undefined;
check_override(EmailAddr, #state{override=Override}) when Override == undefined; Override == []; Override == <<>> ->
    z_convert:to_list(EmailAddr);
check_override(EmailAddr, State) ->
    escape_email(z_convert:to_list(EmailAddr)) ++ " (override) <" ++ State#state.override ++ ">".

escape_email(Email) ->
   escape_email(Email, []).
escape_email([], Acc) ->
    lists:reverse(Acc);
escape_email([$@|T], Acc) ->
    escape_email(T, [$-,$t,$a,$-|Acc]);
escape_email([H|T], Acc) ->
    escape_email(T, [H|Acc]).

optional_render(undefined, undefined, _Vars, _Context) ->
    [];
optional_render(Text, undefined, _Vars, _Context) ->
    Text;
optional_render(undefined, Template, Vars, Context) ->
    {Output, _Context} = z_template:render_to_iolist(Template, Vars, Context),
    binary_to_list(iolist_to_binary(Output)).
    

%% @doc Mark email as sent by adding the 'sent' timestamp. 
%%      This will schedule it for deletion as well.
mark_sent(Id) ->
    Tr = fun() ->
                 [QEmail] = mnesia:read(email_queue, Id),
                 SentTS = now(),
                 mnesia:write(QEmail#email_queue{sent=SentTS})
         end,
    {atomic, SentTimestamp} = mnesia:transaction(Tr),
    SentTimestamp.

%% @doc Deletes a message from the queue.
delete_emailq(Id) ->
    Tr = fun()->
                 [QEmail] = mnesia:read(email_queue, Id),
                 mnesia:delete_object(QEmail)
         end,
    {atomic, ok} = mnesia:transaction(Tr).


%%
%% QUEUEING related functions
%%

%% @doc Fetch a new batch of queued e-mails. Deletes failed messages.
poll_queued(State) ->
    %% delete sent messages
    DelTransFun = fun() -> 
                          DelQuery = qlc:q([QEmail || QEmail <- mnesia:table(email_queue),
                                                      QEmail#email_queue.sent /= undefined andalso
                                                        timer:now_diff(
                                                            inc_timestamp(QEmail#email_queue.sent, ?DELETE_AFTER),
                                                            now()) < 0
                                            ]),
                          DelQueryRes = qlc:e(DelQuery),
                          [ begin
                                mnesia:delete_object(QEmail),
                                {QEmail#email_queue.id,
                                 QEmail#email_queue.recipient,
                                 QEmail#email_queue.pickled_context}
                            end || QEmail <- DelQueryRes ]
                  end,
    {atomic, NotifyList1} = mnesia:transaction(DelTransFun),
    %% notify the system that these emails were sucessfuly sent and (probably) received
    [ z_notifier:first({email_sent, Id, Recipient}, z_context:depickle(PickledContext)) 
     || {Id, Recipient, PickledContext} <- NotifyList1 ],

    %% delete all messages with too high retry count
    SetFailTransFun = fun() ->
                              PollQuery = qlc:q([QEmail || QEmail <- mnesia:table(email_queue),
                                                 QEmail#email_queue.sent == undefined,
                                                 QEmail#email_queue.retry > ?MAX_RETRY]),
                              PollQueryRes = qlc:e(PollQuery),
                              [ begin
                                    mnesia:delete_object(QEmail),
                                    {QEmail#email_queue.id,
                                     QEmail#email_queue.recipient,
                                     QEmail#email_queue.pickled_context}
                                end || QEmail <- PollQueryRes ]
                      end,
    {atomic, NotifyList2} = mnesia:transaction(SetFailTransFun),
    %% notify the system that these emails were failed to be sent
    [ z_notifier:first({email_failed, Id, Recipient}, z_context:depickle(PickledContext)) 
     || {Id, Recipient, PickledContext} <- NotifyList2 ],
 
    %% fetch a batch of messages for sending
    FetchTransFun =
        fun() ->
                Q = qlc:q([QEmail || QEmail <- mnesia:table(email_queue),
                           QEmail#email_queue.sent == undefined,
                           timer:now_diff(QEmail#email_queue.retry_on, now()) < 0]),
                qlc:e(Q)
        end,
    {atomic, Ms} = mnesia:transaction(FetchTransFun),
    %% send the fetched messages
    case Ms of
        [] ->
            State;
        _  ->
            State1 = update_config(State),
            [ begin
                  update_retry(QEmail),
                  spawn_send(QEmail#email_queue.id, 
                             QEmail#email_queue.recipient,
                             QEmail#email_queue.email,
                             z_context:depickle(QEmail#email_queue.pickled_context), 
                             State1)
              end || QEmail <- Ms ],
            State1
    end.


%% @doc Sets the next retry time for an e-mail.
update_retry(QEmail=#email_queue{retry=Retry}) ->
    Period = period(Retry),
    Tr = fun()->
                 mnesia:write(QEmail#email_queue{retry=Retry+1,
                                                 retry_on=inc_timestamp(now(), Period)})
         end,
    mnesia:transaction(Tr).

period(0) -> 10;
period(1) -> 60;
period(2) -> 12 * 60;
period(3) -> 24 * 60;
period(4) -> 48 * 60;
period(5) -> 72 * 60;
period(_) -> 7 * 24 * 60.       % Retry every week for extreme cases
    

%% @doc Increases a timestamp (as returned by now/0) with a value provided in minutes
inc_timestamp({MegaSec, Sec, MicroSec}, MinToAdd) ->
    Sec2 = Sec + MinToAdd, %%!!! * 60,
    Sec3 = Sec2 rem 1000000,
    MegaSec2 = MegaSec + Sec2 div 1000000,
    {MegaSec2, Sec3, MicroSec}.



%% @doc Simple header encoding.
encode_header({Header, [V|Vs]}) when is_list(V) ->
    Hdr = lists:map(fun ({K, Value}) when is_list(K), is_list(Value) ->
                            K ++ "=" ++ Value;
                        ({K, Value}) when is_atom(K), is_list(Value) ->
                            atom_to_list(K) ++ "=" ++ Value;
                        (Value) when is_list(Value) -> Value
                    end,
                    [V|Vs]),
    Header ++ ": " ++ string:join(Hdr, ";\r\n  ");
encode_header({Header, Value})
    when Header =:= "To"; Header =:= "From"; Header =:= "Reply-To"; 
         Header =:= "Cc"; Header =:= "Bcc"; Header =:= "Date";
         Header =:= "Content-Type"; Header =:= "Mime-Version"; Header =:= "MIME-Version";
         Header =:= "Content-Transfer-Encoding" ->
    Value1 = lists:filter(fun(H) -> H >= 32 andalso H =< 126 end, Value),
    Header ++ ": " ++ Value1;
encode_header({Header, Value}) when is_list(Header), is_list(Value) ->
    % Encode all other headers according to rfc2047
    Header ++ ": " ++ rfc2047:encode(Value);
encode_header({Header, Value}) when is_atom(Header), is_list(Value) ->
    atom_to_list(Header) ++ ": " ++ rfc2047:encode(Value).

encode_headers(Headers) ->
    string:join(lists:map(fun encode_header/1, Headers), "\r\n").
