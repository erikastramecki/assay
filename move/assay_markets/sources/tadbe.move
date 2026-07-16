/// Test collateral coin for the Assay ADBE market (devnet demo; mintable via TreasuryCap).
module assay_markets::tadbe {
    use sui::coin::{Self, TreasuryCap};
    public struct TADBE has drop {}
    fun init(w: TADBE, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tADBE", b"Adobe xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TADBE>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
