/// Test collateral coin for the Assay SPY market (devnet demo; mintable via TreasuryCap).
module assay_markets::tspy {
    use sui::coin::{Self, TreasuryCap};
    public struct TSPY has drop {}
    fun init(w: TSPY, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tSPY", b"S&P 500 xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TSPY>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
