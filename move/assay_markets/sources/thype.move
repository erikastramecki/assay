/// Test collateral coin for the Assay HYPE market (devnet demo; mintable via TreasuryCap).
module assay_markets::thype {
    use sui::coin::{Self, TreasuryCap};
    public struct THYPE has drop {}
    fun init(w: THYPE, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tHYPE", b"Hyperliquid", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<THYPE>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
