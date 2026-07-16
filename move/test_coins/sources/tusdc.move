/// Test stable coin (6 decimals) for the Assay Sui devnet lending loop.
/// Mintable via the TreasuryCap held by the publisher — devnet only.
module test_coins::tusdc {
    use sui::coin::{Self, TreasuryCap};

    public struct TUSDC has drop {}

    fun init(witness: TUSDC, ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(
            witness, 6, b"TUSDC", b"Test USDC", b"Assay devnet test stable", option::none(), ctx);
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury, ctx.sender());
    }

    public entry fun mint(cap: &mut TreasuryCap<TUSDC>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
