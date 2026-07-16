/// Test collateral coin for the Assay GOOGL market (devnet demo; mintable via TreasuryCap).
module assay_markets::tgoogl {
    use sui::coin::{Self, TreasuryCap};
    public struct TGOOGL has drop {}
    fun init(w: TGOOGL, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tGOOGL", b"Alphabet xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TGOOGL>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
