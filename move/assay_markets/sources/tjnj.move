/// Test collateral coin for the Assay JNJ market (devnet demo; mintable via TreasuryCap).
module assay_markets::tjnj {
    use sui::coin::{Self, TreasuryCap};
    public struct TJNJ has drop {}
    fun init(w: TJNJ, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tJNJ", b"J&J xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TJNJ>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
