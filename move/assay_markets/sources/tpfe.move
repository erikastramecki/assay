/// Test collateral coin for the Assay PFE market (devnet demo; mintable via TreasuryCap).
module assay_markets::tpfe {
    use sui::coin::{Self, TreasuryCap};
    public struct TPFE has drop {}
    fun init(w: TPFE, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tPFE", b"Pfizer xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TPFE>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
