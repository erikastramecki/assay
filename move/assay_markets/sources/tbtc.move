/// Test collateral coin for the Assay BTC market (devnet demo; mintable via TreasuryCap).
module assay_markets::tbtc {
    use sui::coin::{Self, TreasuryCap};
    public struct TBTC has drop {}
    fun init(w: TBTC, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tBTC", b"BTC", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TBTC>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
