/// Test collateral coin for the Assay LTC market (devnet demo; mintable via TreasuryCap).
module assay_ext_1784082129::tltc {
    use sui::coin::{Self, TreasuryCap};
    public struct TLTC has drop {}
    fun init(w: TLTC, ctx: &mut TxContext) {
        let (t, mt) = coin::create_currency(w, 8, b"tLTC", b"Litecoin", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(mt);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TLTC>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
