/// Test collateral coin for the Assay AVAX market (devnet demo; mintable via TreasuryCap).
module assay_ext_1784082129::tavax {
    use sui::coin::{Self, TreasuryCap};
    public struct TAVAX has drop {}
    fun init(w: TAVAX, ctx: &mut TxContext) {
        let (t, mt) = coin::create_currency(w, 8, b"tAVAX", b"Avalanche", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(mt);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TAVAX>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
