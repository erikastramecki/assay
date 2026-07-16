/// Proof-gated settlement (M4). Funds are locked in a `Vault` and released ONLY
/// when a valid BN254 Groth16 proof is presented whose public input binds this
/// payment. In production the proof is dregg's STARK→Groth16 wrap and the public
/// input is the turn's committed post-state (`final_root`); here the mechanism is
/// identical — only the proof's provenance differs.
module dregg_verifier::settlement {
    use sui::coin::{Self, Coin};
    use sui::event;
    use dregg_verifier::verifier;

    const EBadProof: u64 = 0xBAD;

    /// A locked payment. `payment_id` is the exact public-input bytes the releasing
    /// proof must verify against — this is what binds the proof to THIS payment.
    public struct Vault<phantom T> has key {
        id: UID,
        vk: vector<u8>,
        payment_id: vector<u8>,
        recipient: address,
        funds: Coin<T>,
    }

    public struct Settled has copy, drop { recipient: address, amount: u64 }

    /// Lock `funds` for `recipient`, releasable only by a proof binding `payment_id`.
    public entry fun fund<T>(
        vk: vector<u8>,
        payment_id: vector<u8>,
        recipient: address,
        funds: Coin<T>,
        ctx: &mut TxContext,
    ) {
        transfer::share_object(Vault<T> { id: object::new(ctx), vk, payment_id, recipient, funds });
    }

    /// Present a proof. If it verifies against the vault's `(vk, payment_id)`, the
    /// funds are released to `recipient`; otherwise the tx ABORTS (`EBadProof`) and
    /// nothing moves. This is the on-chain "settle iff proven" gate.
    public entry fun settle<T>(vault: Vault<T>, proof: vector<u8>, _ctx: &mut TxContext) {
        let Vault { id, vk, payment_id, recipient, funds } = vault;
        assert!(verifier::verify(vk, payment_id, proof), EBadProof);
        let amount = coin::value(&funds);
        event::emit(Settled { recipient, amount });
        transfer::public_transfer(funds, recipient);
        object::delete(id);
    }
}
