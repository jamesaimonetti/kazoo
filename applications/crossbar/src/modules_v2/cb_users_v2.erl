%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2014, 2600Hz INC
%%% @doc
%%% Users module
%%%
%%% Handle client requests for user documents
%%%
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cb_users_v2).

-export([create_user/1]).
-export([init/0
         ,allowed_methods/0, allowed_methods/1, allowed_methods/2, allowed_methods/3
         ,resource_exists/0, resource_exists/1, resource_exists/2, resource_exists/3
         ,billing/1
         ,authenticate/1
         ,authorize/1
         ,validate/1, validate/2, validate/3, validate/4
         ,put/1
         ,post/2
         ,delete/2
        ]).

-include("../crossbar.hrl").

-define(SERVER, ?MODULE).
-define(CB_LIST, <<"users/crossbar_listing">>).
-define(LIST_BY_USERNAME, <<"users/list_by_username">>).
-define(CHANNELS, <<"channels">>).
-define(QUICKCALL, <<"quickcall">>).

%%%===================================================================
%%% API
%%%===================================================================

%% SUPPORT FOR THE DEPRECIATED CB_SIGNUPS...
-spec create_user(cb_context:context()) -> cb_context:context().
create_user(Context) ->
    Context1 = validate_request('undefined', cb_context:set_req_verb(Context, ?HTTP_PUT)),
    case cb_context:resp_status(Context1) of
        'success' -> ?MODULE:put(Context1);
        _Status -> Context1
    end.

init() ->
    _ = crossbar_bindings:bind(<<"v2_resource.allowed_methods.users">>, ?MODULE, 'allowed_methods'),
    _ = crossbar_bindings:bind(<<"v2_resource.resource_exists.users">>, ?MODULE, 'resource_exists'),
    _ = crossbar_bindings:bind(<<"v2_resource.authenticate">>, ?MODULE, 'authenticate'),
    _ = crossbar_bindings:bind(<<"v2_resource.authorize">>, ?MODULE, 'authorize'),
    _ = crossbar_bindings:bind(<<"v2_resource.billing">>, ?MODULE, 'billing'),
    _ = crossbar_bindings:bind(<<"v2_resource.validate.users">>, ?MODULE, 'validate'),
    _ = crossbar_bindings:bind(<<"v2_resource.execute.put.users">>, ?MODULE, 'put'),
    _ = crossbar_bindings:bind(<<"v2_resource.execute.post.users">>, ?MODULE, 'post'),
    _ = crossbar_bindings:bind(<<"v2_resource.execute.delete.users">>, ?MODULE, 'delete').

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines the verbs that are appropriate for the
%% given Nouns.  IE: '/accounts/' can only accept GET and PUT
%%
%% Failure here returns 405
%% @end
%%--------------------------------------------------------------------
-spec allowed_methods() -> http_methods().
-spec allowed_methods(path_token()) -> http_methods().
-spec allowed_methods(path_token(), path_token(), path_token()) -> http_methods().

allowed_methods() ->
    [?HTTP_GET, ?HTTP_PUT].

allowed_methods(_) ->
    [?HTTP_GET, ?HTTP_POST, ?HTTP_DELETE].

allowed_methods(_, ?CHANNELS) ->
    [?HTTP_GET].

allowed_methods(_, ?QUICKCALL, _) ->
    [?HTTP_GET].

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the provided list of Nouns are valid.
%%
%% Failure here returns 404
%% @end
%%--------------------------------------------------------------------
-spec resource_exists() -> 'true'.
-spec resource_exists(path_token()) -> 'true'.
-spec resource_exists(path_token(), path_token(), path_token()) -> 'true'.

resource_exists() -> 'true'.
resource_exists(_) -> 'true'.
resource_exists(_, ?CHANNELS) -> 'true'.
resource_exists(_, ?QUICKCALL, _) -> 'true'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec authenticate(cb_context:context()) -> 'true'.
authenticate(Context) ->
    authenticate_users(cb_context:req_nouns(Context), cb_context:req_verb(Context)).

authenticate_users(?USERS_QCALL_NOUNS, ?HTTP_GET) ->
    lager:debug("authenticating request"),
    'true';
authenticate_users(_Nouns, _Verb) -> 'false'.

-spec authorize(cb_context:context()) -> 'true'.
authorize(Context) ->
    authorize_users(cb_context:req_nouns(Context), cb_context:req_verb(Context)).

authorize_users(?USERS_QCALL_NOUNS, ?HTTP_GET) ->
    lager:debug("authorizing request"),
    'true';
authorize_users(_Nouns, _Verb) -> 'false'.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Ensure we will be able to bill for users
%% @end
%%--------------------------------------------------------------------
billing(Context) ->
    process_billing(Context, cb_context:req_nouns(Context), cb_context:req_verb(Context)).

process_billing(Context, [{<<"users">>, _}|_], ?HTTP_GET) ->
    Context;
process_billing(Context, [{<<"users">>, _}|_], _Verb) ->
    try wh_services:allow_updates(cb_context:account_id(Context)) of
        'true' -> Context
    catch
        'throw':{Error, Reason} ->
            crossbar_util:response('error', wh_util:to_binary(Error), 500, Reason, Context)
    end;
process_billing(Context, _Nouns, _Verb) -> Context.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% This function determines if the parameters and content are correct
%% for this request
%%
%% Failure here returns 400
%% @end
%%--------------------------------------------------------------------
-spec validate(cb_context:context()) -> cb_context:context().
-spec validate(cb_context:context(), path_token()) -> cb_context:context().

validate(Context) ->
    validate_users(Context, cb_context:req_verb(Context)).

validate_users(Context, ?HTTP_GET) ->
    load_user_summary(Context);
validate_users(Context, ?HTTP_PUT) ->
    validate_request('undefined', Context).

validate(Context, UserId) ->
    validate_user(Context, UserId, cb_context:req_verb(Context)).

validate_user(Context, UserId, ?HTTP_GET) ->
    load_user(UserId, Context);
validate_user(Context, UserId, ?HTTP_POST) ->
    validate_request(UserId, Context);
validate_user(Context, UserId, ?HTTP_DELETE) ->
    load_user(UserId, Context).

validate(Context, UserId, ?CHANNELS) ->
    Options = [{'key', [UserId, <<"device">>]}
               ,'include_docs'
              ],
    %% TODO: Using the cf_attributes from crossbar isn't exactly kosher
    Context1 = crossbar_doc:load_view(<<"cf_attributes/owned">>, Options, Context),
    case cb_context:has_errors(Context1) of
        'true' -> Context1;
        'false' -> get_channels(Context1)
    end.

validate(Context, UserId, ?QUICKCALL, _) ->
    Context1 = maybe_validate_quickcall(load_user(UserId, Context)),
    case cb_context:has_errors(Context1) of
        'true' -> Context1;
        'false' ->
            cb_modules_util:maybe_originate_quickcall(Context1)
    end.

-spec post(cb_context:context(), path_token()) -> cb_context:context().
post(Context, _) ->
    crossbar_doc:save(Context).

-spec put(cb_context:context()) -> cb_context:context().
put(Context) ->
    DryRun = (not wh_json:is_true(<<"accept_charges">>, cb_context:req_json(Context), 'false')),
    put_resp(DryRun, Context).

put_resp('true', Context) ->
    RespJObj = dry_run(Context),
    case wh_json:is_empty(RespJObj) of
        'false' -> crossbar_util:response_402(RespJObj, Context);
        'true' ->
            NewReqJObj = wh_json:set_value(<<"accept_charges">>, 'true', cb_context:req_json(Context)),
            ?MODULE:put(cb_context:set_req_json(Context, NewReqJObj))
    end;
put_resp('false', Context) ->
    crossbar_doc:save(Context).

-spec dry_run(cb_context:context()) -> wh_json:object().
dry_run(Context) ->
    JObj = cb_context:req_data(Context),
    AccountId = cb_context:account_id(Context),

    UserType = wh_json:get_value(<<"priv_level">>, JObj),
    UserName = wh_json:get_value(<<"username">>, JObj),

    Services = wh_services:fetch(AccountId),
    UpdateServices = wh_service_users:reconcile(Services, UserType),

    Charges = wh_services:activation_charges(<<"devices">>, UserType, Services),

    case Charges > 0 of
        'false' -> wh_services:calculate_charges(UpdateServices, []);
        'true' ->
            Transaction = wh_transaction:debit(AccountId, wht_util:dollars_to_units(Charges)),
            Desc = <<"activation charges for ", UserType/binary , " ", UserName/binary>>,
            Transaction2 = wh_transaction:set_description(Desc, Transaction),
            wh_services:calculate_charges(UpdateServices, [Transaction2])
    end.

-spec delete(cb_context:context(), path_token()) -> cb_context:context().
delete(Context, _) ->
    crossbar_doc:delete(Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec get_channels(cb_context:context()) -> cb_context:context().
get_channels(Context) ->
    Realm = crossbar_util:get_account_realm(cb_context:account_id(Context)),
    Usernames = [Username
                 || JObj <- cb_context:doc(Context),
                    (Username = wh_json:get_value([<<"doc">>
                                                   ,<<"sip">>
                                                   ,<<"username">>
                                                  ], JObj))
                        =/= 'undefined'
                ],
    Req = [{<<"Realm">>, Realm}
           ,{<<"Usernames">>, Usernames}
           | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],
    case whapps_util:amqp_pool_collect(Req
                                       ,fun wapi_call:publish_query_user_channels_req/1
                                       ,{'ecallmgr', 'true'}
                                      )
    of
        {'error', _R} ->
            lager:error("could not reach ecallmgr channels: ~p", [_R]),
            crossbar_util:response('error', <<"could not reach ecallmgr channels">>, Context);
        {_, Resp} ->
            Channels = merge_user_channels_jobjs(Resp),
            crossbar_util:response(Channels, Context)
    end.

-spec merge_user_channels_jobjs(wh_json:objects()) -> wh_json:objects().
merge_user_channels_jobjs(JObjs) ->
    merge_user_channels_jobjs(JObjs, dict:new()).

-spec merge_user_channels_jobjs(wh_json:objects(), dict()) -> wh_json:objects().
merge_user_channels_jobjs([], Dict) ->
    [Channel || {_, Channel} <- dict:to_list(Dict)];
merge_user_channels_jobjs([JObj|JObjs], Dict) ->
    merge_user_channels_jobjs(JObjs, merge_user_channels_jobj(JObj, Dict)).

-spec merge_user_channels_jobj(wh_json:object(), dict()) -> dict().
merge_user_channels_jobj(JObj, Dict) ->
    lists:foldl(fun merge_user_channels_fold/2, Dict, wh_json:get_value(<<"Channels">>, JObj, [])).

-spec merge_user_channels_fold(wh_json:object(), dict()) -> dict().
merge_user_channels_fold(Channel, D) ->
    UUID = wh_json:get_value(<<"uuid">>, Channel),
    dict:store(UUID, Channel, D).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Attempt to load list of accounts, each summarized.  Or a specific
%% account summary.
%% @end
%%--------------------------------------------------------------------
-spec load_user_summary(cb_context:context()) -> cb_context:context().
load_user_summary(Context) ->
    crossbar_doc:load_view(?CB_LIST, [], Context, fun normalize_view_results/2).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Load a user document from the database
%% @end
%%--------------------------------------------------------------------
-spec load_user(api_binary(), cb_context:context()) -> cb_context:context().
load_user(UserId, Context) -> crossbar_doc:load(UserId, Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec validate_request(api_binary(), cb_context:context()) -> cb_context:context().
validate_request(UserId, Context) ->
    prepare_username(UserId, Context).

prepare_username(UserId, Context) ->
    JObj = cb_context:req_data(Context),
    case wh_json:get_ne_value(<<"username">>, JObj) of
        'undefined' -> check_user_schema(UserId, Context);
        Username ->
            JObj1 = wh_json:set_value(<<"username">>, wh_util:to_lower_binary(Username), JObj),
            check_user_schema(UserId, cb_context:set_req_data(Context, JObj1))
    end.

check_user_schema(UserId, Context) ->
    OnSuccess = fun(C) -> on_successful_validation(UserId, C) end,
    cb_context:validate_request_data(<<"users">>, Context, OnSuccess).

on_successful_validation('undefined', Context) ->
    Props = [{<<"pvt_type">>, <<"user">>}],
    maybe_import_credintials('undefined'
                             ,cb_context:set_doc(Context
                                                 ,wh_json:set_values(Props, cb_context:doc(Context))
                                                )
                            );
on_successful_validation(UserId, Context) ->
    maybe_import_credintials(UserId, crossbar_doc:load_merge(UserId, Context)).

-spec maybe_import_credintials(ne_binary(), cb_context:context()) -> cb_context:context().
maybe_import_credintials(UserId, Context) ->
    JObj = cb_context:doc(Context),
    case wh_json:get_ne_value(<<"credentials">>, JObj) of
        'undefined' -> maybe_validate_username(UserId, Context);
        Creds ->
            RemoveKeys = [<<"credentials">>, <<"pvt_sha1_auth">>],
            C = cb_context:set_doc(Context
                                   ,wh_json:set_value(<<"pvt_md5_auth">>, Creds
                                                      ,wh_json:delete_keys(RemoveKeys, JObj)
                                                     )
                                  ),
            maybe_validate_username(UserId, C)
    end.

-spec maybe_validate_username(ne_binary(), cb_context:context()) -> cb_context:context().
maybe_validate_username(UserId, Context) ->
    JObj = cb_context:doc(Context),
    NewUsername = wh_json:get_ne_value(<<"username">>, JObj),
    CurrentUsername =
        case cb_context:fetch(Context, 'db_doc') of
            'undefined' -> NewUsername;
            CurrentJObj ->
                wh_json:get_ne_value(<<"username">>, CurrentJObj, NewUsername)
        end,
    case wh_util:is_empty(NewUsername)
        orelse CurrentUsername =:= NewUsername
        orelse username_doc_id(NewUsername, Context)
    of
        %% username is unchanged
        'true' -> maybe_rehash_creds(UserId, NewUsername, Context);
        %% updated username that doesnt exist
        'undefined' ->
            manditory_rehash_creds(UserId, NewUsername, Context);
        %% updated username to existing, collect any further errors...
        _Else ->
            C = cb_context:add_validation_error(<<"username">>
                                                ,<<"unique">>
                                                ,<<"Username is not unique for this account">>
                                                ,Context
                                               ),
            manditory_rehash_creds(UserId, NewUsername, C)
    end.

maybe_rehash_creds(UserId, Username, Context) ->
    case wh_json:get_ne_value(<<"password">>, cb_context:doc(Context)) of
        %% No username or hash, no creds for you!
        'undefined' when Username =:= 'undefined' ->
            HashKeys = [<<"pvt_md5_auth">>, <<"pvt_sha1_auth">>],
            cb_context:set_doc(Context, wh_json:delete_keys(HashKeys, cb_context:doc(Context)));
        %% Username without password, creds status quo
        'undefined' -> Context;
        %% Got a password, hope you also have a username...
        Password -> rehash_creds(UserId, Username, Password, Context)
    end.

-spec manditory_rehash_creds(ne_binary(), ne_binary(), cb_context:context()) ->
                                    cb_context:context().
manditory_rehash_creds(UserId, Username, Context) ->
    case wh_json:get_ne_value(<<"password">>, cb_context:doc(Context)) of
        'undefined' ->
            cb_context:add_validation_error(<<"password">>
                                            ,<<"required">>
                                            ,<<"The password must be provided when updating the username">>
                                            ,Context
                                           );
        Password -> rehash_creds(UserId, Username, Password, Context)
    end.

-spec rehash_creds(_, api_binary(), ne_binary(), cb_context:context()) ->
                          cb_context:context().
rehash_creds(_, 'undefined', _, Context) ->
    cb_context:add_validation_error(<<"username">>
                                    ,<<"required">>
                                    ,<<"The username must be provided when updating the password">>
                                    ,Context
                                   );
rehash_creds(_, Username, Password, Context) ->
    lager:debug("password set on doc, updating hashes for ~s", [Username]),
    {MD5, SHA1} = cb_modules_util:pass_hashes(Username, Password),
    JObj1 = wh_json:set_values([{<<"pvt_md5_auth">>, MD5}
                                ,{<<"pvt_sha1_auth">>, SHA1}
                               ], cb_context:doc(Context)),
    cb_context:set_doc(Context, wh_json:delete_key(<<"password">>, JObj1)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec maybe_validate_quickcall(cb_context:context()) -> cb_context:context().
-spec maybe_validate_quickcall(cb_context:context(), crossbar_status()) -> cb_context:context().
maybe_validate_quickcall(Context) ->
    maybe_validate_quickcall(Context, cb_context:resp_status(Context)).

maybe_validate_quickcall(Context, 'success') ->
    case (not wh_util:is_empty(cb_context:auth_token(Context)))
        orelse wh_json:is_true(<<"allow_anoymous_quickcalls">>, cb_context:doc(Context))
    of
        'false' -> cb_context:add_system_error('invalid_credentials', Context);
        'true' -> Context
    end;
maybe_validate_quickcall(Context, _) ->
    cb_context:add_system_error('invalid_credentials', Context).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function will determine if the username in the request is
%% unique or belongs to the request being made
%% @end
%%--------------------------------------------------------------------
-spec username_doc_id(api_binary(), cb_context:context()) -> api_binary().
username_doc_id(Username, Context) ->
    username_doc_id(Username, Context, cb_context:account_db(Context)).
username_doc_id(_, _, 'undefined') -> 'undefined';
username_doc_id(Username, Context, _AccountDb) ->
    Username = wh_util:to_lower_binary(Username),
    Context1 = crossbar_doc:load_view(?LIST_BY_USERNAME, [{'key', Username}], Context),
    case cb_context:resp_status(Context1) =:= 'success'
        andalso cb_context:doc(Context1)
    of
        [JObj] -> wh_json:get_value(<<"id">>, JObj);
        _ -> 'undefined'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Normalizes the resuts of a view
%% @end
%%--------------------------------------------------------------------
-spec(normalize_view_results(wh_json:object(), wh_json:objects()) -> wh_json:objects()).
normalize_view_results(JObj, Acc) -> [wh_json:get_value(<<"value">>, JObj)|Acc].
