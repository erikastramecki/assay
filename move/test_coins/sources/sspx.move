/// Test tokenized-stock collateral (8 decimals) — stands in for an xStock (e.g. TSLAx)
/// in the Assay Sui devnet lending loop. Mintable via TreasuryCap — devnet only.
module test_coins::sspx {
    use sui::coin::{Self, TreasuryCap};

    public struct SSPX has drop {}

    fun init(witness: SSPX, ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(
            witness, 8, b"SSPX", b"Test xStock", b"Assay devnet test RWA collateral", option::none(), ctx);
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury, ctx.sender());
    }

    public entry fun mint(cap: &mut TreasuryCap<SSPX>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
