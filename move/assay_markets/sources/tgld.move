/// Test collateral coin for the Assay GLD market (devnet demo; mintable via TreasuryCap).
module assay_markets::tgld {
    use sui::coin::{Self, TreasuryCap};
    public struct TGLD has drop {}
    fun init(w: TGLD, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tGLD", b"Gold xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TGLD>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
