/// Test collateral coin for the Assay GME market (devnet demo; mintable via TreasuryCap).
module assay_markets::tgme {
    use sui::coin::{Self, TreasuryCap};
    public struct TGME has drop {}
    fun init(w: TGME, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tGME", b"GameStop xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TGME>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
