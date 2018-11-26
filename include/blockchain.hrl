% Protocols
-define(GOSSIP_PROTOCOL, "blockchain_gossip/1.0.0").
-define(SYNC_PROTOCOL, "blockchain_sync/1.0.0").
-define(TX_PROTOCOL, "blockchain_txn/1.0.0").
-define(GW_REGISTRATION_PROTOCOL, "gw_registration/1.0.0").
-define(LOC_ASSERTION_PROTOCOL, "loc_assertion/1.0.0").

% Directory / File
-define(BASE_DIR, "blockchain").
-define(BLOCKS_DIR, "blocks").
-define(HEIGHTS_DIR, "heights").
-define(GEN_HASH_FILE, "genesis").
-define(HEAD_FILE, "head").
-define(LEDGER_FILE, "ledger").

% B58 Address Versions
-define(MAINNET_VER, 0).
-define(TESTNET_VER, 2).
-define(HTLC_VER, 24).

% Misc
-define(EVT_MGR, blockchain_event_mgr).
