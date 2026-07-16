/// Test collateral coin for the Assay TSLA market (devnet demo; mintable via TreasuryCap).
module assay_markets::ttsla {
    use sui::coin::{Self, TreasuryCap};
    public struct TTSLA has drop {}
    fun init(w: TTSLA, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tTSLA", b"Tesla xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TTSLA>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
