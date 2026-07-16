/// Test collateral coin for the Assay AMZN market (devnet demo; mintable via TreasuryCap).
module assay_markets::tamzn {
    use sui::coin::{Self, TreasuryCap};
    public struct TAMZN has drop {}
    fun init(w: TAMZN, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tAMZN", b"Amazon xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TAMZN>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
