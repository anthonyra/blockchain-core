%%%-------------------------------------------------------------------
%% @doc
%% == Blockchain Transaction Payment ==
%% @end
%%%-------------------------------------------------------------------
-module(blockchain_txn_payment_v1).

-behavior(blockchain_txn).

-behavior(blockchain_json).
-include("blockchain_json.hrl").
-include("blockchain_txn_fees.hrl").
-include("blockchain_utils.hrl").
-include("blockchain_vars.hrl").
-include_lib("helium_proto/include/blockchain_txn_payment_v1_pb.hrl").

-export([
    new/4,
    hash/1,
    payer/1,
    payee/1,
    amount/1,
    fee/1, fee/2,
    fee_payer/2,
    calculate_fee/2, calculate_fee/5,
    nonce/1,
    signature/1,
    sign/2,
    is_valid/2,
    is_well_formed/1,
    is_absorbable/2,
    absorb/2,
    print/1,
    json_type/0,
    to_json/2
]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type txn_payment() :: #blockchain_txn_payment_v1_pb{}.
-export_type([txn_payment/0]).

-spec new(libp2p_crypto:pubkey_bin(), libp2p_crypto:pubkey_bin(), pos_integer(),
          non_neg_integer()) -> txn_payment().
new(Payer, Recipient, Amount, Nonce) ->
    #blockchain_txn_payment_v1_pb{
        payer=Payer,
        payee=Recipient,
        amount=Amount,
        fee=?LEGACY_TXN_FEE,
        nonce=Nonce,
        signature = <<>>
    }.

-spec hash(txn_payment()) -> blockchain_txn:hash().
hash(Txn) ->
    BaseTxn = Txn#blockchain_txn_payment_v1_pb{signature = <<>>},
    EncodedTxn = blockchain_txn_payment_v1_pb:encode_msg(BaseTxn),
    crypto:hash(sha256, EncodedTxn).

-spec payer(txn_payment()) -> libp2p_crypto:pubkey_bin().
payer(Txn) ->
    Txn#blockchain_txn_payment_v1_pb.payer.

-spec payee(txn_payment()) -> libp2p_crypto:pubkey_bin().
payee(Txn) ->
    Txn#blockchain_txn_payment_v1_pb.payee.

-spec amount(txn_payment()) -> non_neg_integer().
amount(Txn) ->
    Txn#blockchain_txn_payment_v1_pb.amount.

-spec fee(txn_payment()) -> non_neg_integer().
fee(Txn) ->
    Txn#blockchain_txn_payment_v1_pb.fee.

-spec fee(txn_payment(), non_neg_integer()) -> txn_payment().
fee(Txn, Fee) ->
    Txn#blockchain_txn_payment_v1_pb{fee=Fee}.

-spec fee_payer(txn_payment(), blockchain_ledger_v1:ledger()) -> libp2p_crypto:pubkey_bin() | undefined.
fee_payer(Txn, _Ledger) ->
    payer(Txn).

-spec nonce(txn_payment()) -> non_neg_integer().
nonce(Txn) ->
    Txn#blockchain_txn_payment_v1_pb.nonce.

-spec signature(txn_payment()) -> binary().
signature(Txn) ->
    Txn#blockchain_txn_payment_v1_pb.signature.

%%--------------------------------------------------------------------
%% @doc
%% NOTE: payment transactions can be signed either by a worker who's part of the blockchain
%% or through the wallet? In that case presumably the wallet uses its private key to sign the
%% payment transaction.
%% @end
%%--------------------------------------------------------------------
-spec sign(txn_payment(), libp2p_crypto:sig_fun()) -> txn_payment().
sign(Txn, SigFun) ->
    EncodedTxn = blockchain_txn_payment_v1_pb:encode_msg(Txn),
    Txn#blockchain_txn_payment_v1_pb{signature=SigFun(EncodedTxn)}.

%%--------------------------------------------------------------------
%% @doc
%% Calculate the txn fee
%% Returned value is txn_byte_size / 24
%% @end
%%--------------------------------------------------------------------
-spec calculate_fee(txn_payment(), blockchain:blockchain()) -> non_neg_integer().
calculate_fee(Txn, Chain) ->
    ?calculate_fee_prep(Txn, Chain).

-spec calculate_fee(txn_payment(), blockchain_ledger_v1:ledger(), pos_integer(), pos_integer(), boolean()) -> non_neg_integer().
calculate_fee(_Txn, _Ledger, _DCPayloadSize, _TxnFeeMultiplier, false) ->
    ?LEGACY_TXN_FEE;
calculate_fee(Txn, Ledger, DCPayloadSize, TxnFeeMultiplier, true) ->
    ?calculate_fee(Txn#blockchain_txn_payment_v1_pb{fee=0, signature = <<0:512>>}, Ledger, DCPayloadSize, TxnFeeMultiplier).

is_valid_sig(Txn) ->
    PubKey = libp2p_crypto:bin_to_pubkey(payer(Txn)),
    Signature = ?MODULE:signature(Txn),
    BaseTxn = Txn#blockchain_txn_payment_v1_pb{signature = <<>>},
    EncodedTxn = blockchain_txn_payment_v1_pb:encode_msg(BaseTxn),
    libp2p_crypto:verify(EncodedTxn, Signature, PubKey).

is_valid_nonce(Txn, Ledger) ->
    case blockchain_ledger_v1:find_entry(payer(Txn), Ledger) of
        {error, _}=Error0 ->
            Error0;
        {ok, Entry} ->
            TxnNonce = ?MODULE:nonce(Txn),
            LedgerNonce = blockchain_ledger_entry_v1:nonce(Entry),
            case TxnNonce =:= LedgerNonce + 1 of
                false ->
                    {error, {bad_nonce, {payment, TxnNonce, LedgerNonce}}};
                true ->
                    ok
            end
    end.

is_valid_amount(Txn, Ledger) ->
    Min =
        case blockchain:config(?allow_zero_amount, Ledger) of
            {ok, false} -> 1;
            _ -> 0
        end,
    amount(Txn) >= Min.

%% TODO Rename func prefixes to reflect codomain. is_* boolean(), ?_* result()

-spec is_valid(txn_payment(), blockchain:blockchain()) -> ok | {error, _}.
is_valid(Txn, Chain) ->
    true = blockchain_contracts:is_satisfied(payer(Txn), {'not', {val, payee(Txn)}}),
    Ledger = blockchain:ledger(Chain),
    case is_valid_payee(Txn, Ledger) of
        false ->
            {error, invalid_payee};
        true ->
            case is_valid_sig(Txn) of
                false ->
                    {error, bad_signature};
                true ->
                    case is_valid_amount(Txn, Ledger) of
                        false ->
                            {error, invalid_transaction};
                        true ->
                            is_valid_fee(Txn, Chain, Ledger)
                    end
            end
    end.

-spec is_well_formed(txn_payment()) -> ok | {error, _}.
is_well_formed(#blockchain_txn_payment_v1_pb{
    payer     = Payer,
    payee     = Payee,
    amount    = Amount,
    fee       = Fee,
    nonce     = Nonce,
    signature = Signature
}) ->
    %% XXX Destructure is better than accessors for cases where _everything_
    %% needs accessing. When only one name is bound and then passed to multiple
    %% functions, it is easy to make the mistake of calling the same accessor
    %% more than once, without violating any language rules; but, when
    %% destructuring and binding multiple names, we get either a warning for an
    %% unused or a reused binding.
    %% TODO Should ?txn_field_validation_version matter here?
    blockchain_contracts:check([
        {payer     , Payer    , {forall, [{address, libp2p}, {'not', {val, Payee}}]}},
        {payee     , Payee    , {forall, [{binary, any}, {'not', {val, Payer}}]}},
        {amount    , Amount   , {integer, {min, 0}}},  % TODO Limit to 64bit?
        {fee       , Fee      , {integer, {min, 0}}},  % TODO Limit to 64bit?
        {nonce     , Nonce    , {integer, {min, 1}}},  % TODO Limit to 64bit?
        {signature , Signature, {binary, any}}         % TODO Size constraint?
    ]).

is_valid_payee(Txn, Ledger) ->
    Contract =
        case blockchain:config(?txn_field_validation_version, Ledger) of
            {ok, 1} -> {address, libp2p};
            _       -> {binary, {range, 20, 33}}
        end,
    blockchain_contracts:is_satisfied(payee(Txn), Contract).

is_valid_fee(Txn, Chain, Ledger) ->
    AreFeesEnabled = blockchain_ledger_v1:txn_fees_active(Ledger),
    ExpectedTxnFee = calculate_fee(Txn, Chain),
    TxnFee = fee(Txn),
    case ExpectedTxnFee =< TxnFee orelse not AreFeesEnabled of
        false ->
            {error, {wrong_txn_fee, {ExpectedTxnFee, TxnFee}}};
        true ->
            Payer = ?MODULE:payer(Txn),
            blockchain_ledger_v1:check_dc_or_hnt_balance(Payer, TxnFee, Ledger, AreFeesEnabled)
    end.

-spec is_absorbable(txn_payment(), blockchain:blockchain()) ->
    boolean().
is_absorbable(Txn, Chain) ->
    Ledger = blockchain:ledger(Chain),
    case blockchain:config(?deprecate_payment_v1, Ledger) of
        {ok, true} ->
            lager:error("payment_v1 deprecated"),
            false;
        _ ->
            is_valid_nonce(Txn, Ledger)
    end.

-spec absorb(txn_payment(), blockchain:blockchain()) -> ok | {error, atom()} | {error, {atom(), any()}}.
absorb(Txn, Chain) ->
    Ledger = blockchain:ledger(Chain),
    Amount = ?MODULE:amount(Txn),
    TxnFee = ?MODULE:fee(Txn),
    TxnHash = ?MODULE:hash(Txn),
    Payer = ?MODULE:payer(Txn),
    Nonce = ?MODULE:nonce(Txn),
    AreFeesEnabled = blockchain_ledger_v1:txn_fees_active(Ledger),
    case blockchain_ledger_v1:debit_fee(Payer, TxnFee, Ledger, AreFeesEnabled, TxnHash, Chain) of
        {error, _Reason}=Error -> Error;
        ok ->
            case blockchain_ledger_v1:debit_account(Payer, Amount, Nonce, Ledger) of
                {error, _Reason}=Error ->
                    Error;
                ok ->
                    Payee = ?MODULE:payee(Txn),
                    blockchain_ledger_v1:credit_account(Payee, Amount, Ledger)
            end
    end.

-spec print(txn_payment()) -> iodata().
print(undefined) -> <<"type=payment, undefined">>;
print(#blockchain_txn_payment_v1_pb{payer=Payer, payee=Recipient, amount=Amount,
                                    fee=Fee, nonce=Nonce, signature = S }) ->
    io_lib:format("type=payment, payer=~p, payee=~p, amount=~p, fee=~p, nonce=~p, signature=~s",
                  [?TO_B58(Payer), ?TO_B58(Recipient), Amount, Fee, Nonce, ?TO_B58(S)]).

json_type() ->
    <<"payment_v1">>.

-spec to_json(txn_payment(), blockchain_json:opts()) -> blockchain_json:json_object().
to_json(Txn, _Opts) ->
    #{
      type => ?MODULE:json_type(),
      hash => ?BIN_TO_B64(hash(Txn)),
      payer => ?BIN_TO_B58(payer(Txn)),
      payee => ?BIN_TO_B58(payee(Txn)),
      amount => amount(Txn),
      fee => fee(Txn),
      nonce => nonce(Txn)
     }.

%% ------------------------------------------------------------------
%% EUNIT Tests
%% ------------------------------------------------------------------
-ifdef(TEST).

new_test() ->
    Tx = #blockchain_txn_payment_v1_pb{
        payer= <<"payer">>,
        payee= <<"payee">>,
        amount=666,
        fee=?LEGACY_TXN_FEE,
        nonce=1,
        signature = <<>>
    },
    ?assertEqual(Tx, new(<<"payer">>, <<"payee">>, 666, 1)).

payer_test() ->
    Tx = new(<<"payer">>, <<"payee">>, 666, 1),
    ?assertEqual(<<"payer">>, payer(Tx)).

payee_test() ->
    Tx = new(<<"payer">>, <<"payee">>, 666, 1),
    ?assertEqual(<<"payee">>, payee(Tx)).


amount_test() ->
    Tx = new(<<"payer">>, <<"payee">>, 666, 1),
    ?assertEqual(666, amount(Tx)).

fee_test() ->
    Tx = new(<<"payer">>, <<"payee">>, 666, 1),
    ?assertEqual(?LEGACY_TXN_FEE, fee(Tx)).

nonce_test() ->
    Tx = new(<<"payer">>, <<"payee">>, 666, 1),
    ?assertEqual(1, nonce(Tx)).

signature_test() ->
    Tx = new(<<"payer">>, <<"payee">>, 666, 1),
    ?assertEqual(<<>>, signature(Tx)).

sign_test() ->
    #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
    Tx0 = new(<<"payer">>, <<"payee">>, 666, 1),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Tx1 = sign(Tx0, SigFun),
    Sig1 = signature(Tx1),
    EncodedTx1 = blockchain_txn_payment_v1_pb:encode_msg(Tx1#blockchain_txn_payment_v1_pb{signature = <<>>}),
    ?assert(libp2p_crypto:verify(EncodedTx1, Sig1, PubKey)).

to_json_test() ->
    Tx = new(<<"payer">>, <<"payee">>, 666, 1),
    Json = to_json(Tx, []),
    ?assert(lists:all(fun(K) -> maps:is_key(K, Json) end,
                      [type, hash, payer, payee, amount, fee, nonce])).

-define(TSET(T, K, V), T#blockchain_txn_payment_v1_pb{K = V}).

is_well_formed_test_() ->
    Addr =
        fun () ->
            #{public := P, secret := _} = libp2p_crypto:generate_keys(ecc_compact),
            libp2p_crypto:pubkey_to_bin(P)
        end,
    Payer = Addr(),
    Payee = Addr(),
    T =
        #blockchain_txn_payment_v1_pb{
            payer     = Payer,
            payee     = Payee,
            amount    = 1,
            fee       = 1,
            nonce     = 1,
            signature = <<>>
        },
    [
        ?_assertMatch(ok, is_well_formed(T)),

        %% No self-payment is allowed
        ?_assertMatch({error, {invalid, [{payer, _}, {payee, _}]}}, is_well_formed(?TSET(T, payer, Payee))),
        ?_assertMatch({error, {invalid, [{payer, _}, {payee, _}]}}, is_well_formed(?TSET(T, payee, Payer))),

        %% Must be a binary
        ?_assertMatch({error, {invalid, [{payee, {not_a_binary, _}}]}}, is_well_formed(?TSET(T, payee, undefined))),
        ?_assertMatch({error, {invalid, [{payee, {not_a_binary, _}}]}}, is_well_formed(?TSET(T, payee, 0))),
        ?_assertMatch({error, {invalid, [{payee, {not_a_binary, _}}]}}, is_well_formed(?TSET(T, payee, "not addr"))),

        %% But, more-refined validation will happen later, in is_valid/2
        ?_assertMatch(ok, is_well_formed(?TSET(T, payee, <<>>))),
        ?_assertMatch(ok, is_well_formed(?TSET(T, payee, <<"not addr">>))),

        ?_assertMatch({error, {invalid, [{amount, {not_an_integer, _}}]}}, is_well_formed(?TSET(T, amount, undefined))),
        ?_assertMatch({error, {invalid, [{amount, {integer_out_of_range, _, _}}]}}, is_well_formed(?TSET(T, amount, -1))),
        ?_assertMatch({error, {invalid, [{fee, {integer_out_of_range, _, _}}]}}, is_well_formed(?TSET(T, fee, -1))),
        ?_assertMatch({error, {invalid, [{nonce, {integer_out_of_range, _, _}}]}}, is_well_formed(?TSET(T, nonce, -1)))
    ].

is_valid_with_extended_validation_test() ->
    {timeout, 30000,
     fun() ->
             BaseDir = test_utils:tmp_dir("is_valid_with_extended_validation_test"),
             Block = blockchain_block:new_genesis_block([]),
             {ok, Chain} = blockchain:new(BaseDir, Block, undefined, undefined),
             meck:new(blockchain_ledger_v1, [passthrough]),

             %% These are all required
             meck:expect(blockchain_ledger_v1, config,
                         fun(?deprecate_payment_v1, _) ->
                                 {ok, false};
                            (?txn_field_validation_version, _) ->
                                 %% This is new
                                 {ok, 1};
                            (?allow_zero_amount, _) ->
                                 {ok, false};
                            (?dc_payload_size, _) ->
                                 {error, not_found};
                            (?txn_fee_multiplier, _) ->
                                 {error, not_found}
                         end),
             meck:expect(blockchain_ledger_v1, txn_fees_active, fun(_) -> true end),

             #{public := PubKey, secret := PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
             SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
             Payer = libp2p_crypto:pubkey_to_bin(PubKey),
             Tx = sign(new(Payer, <<"payee">>, 666, 1), SigFun),
             ?assertEqual({error, {invalid_address, payee}}, is_valid(Tx, Chain)),

             Tx1 = sign(new(Payer, libp2p_crypto:b58_to_bin("1BR9RgYoP5psbcw9aKh1cDskLaGMBmkb8"), 666, 1), SigFun),
             ?assertEqual({error, {invalid_address, payee}}, is_valid(Tx1, Chain)),

             #{public := PayeePubkey, secret := _PrivKey} = libp2p_crypto:generate_keys(ecc_compact),
             ValidPayee = libp2p_crypto:pubkey_to_bin(PayeePubkey),
             Tx2 = sign(new(Payer, ValidPayee, 666, 1), SigFun),
             %% This check can be improved but whatever (it fails on fee)
             ?assertNotEqual({error, {invalid_address, payee}}, is_valid(Tx2, Chain)),

             meck:unload(blockchain_ledger_v1),
             test_utils:cleanup_tmp_dir(BaseDir)
     end}.

-endif.
