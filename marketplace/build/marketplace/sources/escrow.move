module marketplace::escrow {
    use kiosk::{
        floor_price_rule as floor_rule,
        kiosk_lock_rule as lock_rule,
        royalty_rule::{Self, Rule as RoyaltyRule}
    };
    use marketplace::{marketplace::{Self as market_p, MarketPlace, OfferCap}, utils};
    use std::string::String;
    use sui::{
        balance::Balance,
        coin::{Self, Coin},
        event::emit,
        kiosk::{Kiosk, KioskOwnerCap},
        kiosk_extension,
        sui::SUI,
        transfer_policy::{TransferPolicy, TransferRequest}
    };

    // ====================== Errors ======================
    const ECanNotPlaceToExtension: u64 = 410;
    const EInsufficientAmount: u64 = 411;
    const EItemNotFound: u64 = 412;

    // ====================== Structs ======================

    public struct Offer<phantom T: key + store> has key, store {
        id: UID,
        kiosk: ID,
        owner: address,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
        balance: Balance<SUI>,
        offer_cap: ID,
    }

    public struct OfferWrapper<phantom T: key + store> {
        offer: Offer<T>,
    }

    public struct OfferKey<phantom T: key + store> has copy, drop, store {
        offer: ID,
        item: ID,
    }

    public struct Ext has drop {}

    // ====================== Events ======================

    public struct OfferEvent has copy, drop {
        kiosk: ID,
        offer_id: ID,
        offer_cap: ID,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    }

    public struct RevokeOfferEvent has copy, drop {
        kiosk: ID,
        offer_id: ID,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    }

    public struct AcceptOfferEvent has copy, drop {
        kiosk: ID,
        offer_id: ID,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
        offer_cap: ID,
    }

    public struct DeclineOfferEvent has copy, drop {
        kiosk: ID,
        offer_id: ID,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
        offer_cap: ID,
    }

    // ====================== User Functions ======================
    /// @dev Creates and store an offer for an item in the kiosk extension.
    ///      This includes initializing the required offer object, configuring the kiosk extension if necessary,
    ///      and emitting an event for the created offer.
    /// @param kiosk A mutable reference to the kiosk where the offer will be stored.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param item_id The ID of the item being offered.
    /// @param price The price of the item (in mist unit).
    /// @param payment A Coin<SUI> object representing the payment.
    /// @param policy A reference to the transfer policy applied to the offer.
    /// @param market A reference to the marketplace where the offer is being made.
    /// @param ctx The transaction context of the sender.
    #[allow(lint(self_transfer))]
    public fun offer<T: key + store>(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        item_id: ID,
        // price: u64,
        payment: Coin<SUI>,
        policy: &TransferPolicy<T>,
        market: &MarketPlace,
        ctx: &mut TxContext,
    ) {
        let (offer, offer_cap) = new_offer<T>(
            kiosk,
            kiosk_cap,
            item_id,
            // price,
            payment,
            policy,
            market,
            ctx,
        );

        let offer_id = object::id(&offer);
        let offer_cap_id = object::id(&offer_cap);

        // if kiosk has no extension or extension is disabled -> install or enable extension
        if (kiosk_extension::is_installed<Ext>(kiosk) == false) {
            kiosk_extension::add(Ext {}, kiosk, kiosk_cap, 3, ctx);
        } else if (kiosk_extension::is_enabled<Ext>(kiosk) == false) {
            kiosk_extension::enable<Ext>(kiosk, kiosk_cap);
        };

        emit_offer_event(
            offer.kiosk,
            offer_id,
            offer_cap_id,
            offer.item,
            offer.item_type,
            offer.price,
            offer.royalty_fee,
            offer.market_fee,
        );

        // store Offer<T> object into kiosk extension storage
        kiosk_extension::storage_mut(Ext {}, kiosk).add(
            OfferKey<T> { offer: object::id(&offer), item: item_id },
            offer,
        );

        // transfer OfferCap<T> to offerer
        offer_cap.transfer_offer_cap(ctx);
    }

    /// @dev Revokes an existing offer in the marketplace. This function removes the offer from
    ///      the kiosk's storage, deletes the offer and its capability, and refunds the balance to
    ///      the sender.
    /// @param kiosk A mutable reference to the kiosk where the offer was stored.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param offer_id The ID of the offer being revoked.
    /// @param item_id The ID of the item associated with the offer.
    /// @param offer_cap The capability object associated with the offer being revoked.
    /// @param ctx The transaction context of the sender.
    #[allow(lint(self_transfer))]
    public fun revoke_offer<T: key + store>(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        offer_id: ID,
        item_id: ID,
        offer_cap: OfferCap,
        ctx: &mut TxContext,
    ) {
        offer_cap.assert_offer_match(offer_id);

        assert!(kiosk.has_access(kiosk_cap), 100);

        let offer = kiosk_extension::storage_mut(Ext {}, kiosk).remove<
            OfferKey<T>,
            Offer<T>,
        >(OfferKey<T> { offer: offer_id, item: item_id });
        let offer_id = object::id(&offer);
        let Offer {
            id,
            kiosk,
            owner: _,
            item,
            item_type,
            price,
            market_fee,
            royalty_fee,
            balance,
            offer_cap: _,
        } = offer;
        object::delete(id);
        offer_cap.delete_cap();

        emit_revoke_offer_event(kiosk, offer_id, item, item_type, price, royalty_fee, market_fee);

        let mut coin = coin::zero(ctx);
        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, tx_context::sender(ctx));
    }

    /// @dev Accepts an offer in the marketplace. Transfers the item to the accepter's kiosk,
    ///      deducts and distributes fees (market and royalty), and processes the item transfer based
    ///      on the associated transfer policy.
    /// @notice After calling `accept_offer`, the client-side must fulfill the custom transfer policy rules.
    ///         The `confirm_offer_accepted` function should be executed last to finalize the offer acceptance.
    ///         The `OfferWrapper` is a hotpotato and should be processed in `confirm_offer_accepted`.
    /// @param offerer_kiosk A mutable reference to the kiosk of the offerer where the offer exists.
    /// @param offer_id The ID of the offer being accepted.
    /// @param accepter_kiosk A mutable reference to the kiosk of the accepter where the item was stored.
    /// @param accepter_kiosk_cap A capability object that allows modification of the accepter's kiosk.
    /// @param item_id The ID of the item being transferred.
    /// @param policy A mutable reference to the transfer policy applied to the item.
    /// @param market A mutable reference to the marketplace where the market fee is paid.
    /// @param ctx The transaction context of the sender.
    /// @return A tuple containing an `OfferWrapper<T>` for the accepted offer and a `TransferRequest<T>` for the item transfer.
    public fun accept_offer<T: key + store>(
        offerer_kiosk: &mut Kiosk,
        offer_id: ID,
        accepter_kiosk: &mut Kiosk,
        accepter_kiosk_cap: &KioskOwnerCap,
        item_id: ID,
        policy: &mut TransferPolicy<T>,
        market: &mut MarketPlace,
        ctx: &mut TxContext,
    ): (OfferWrapper<T>, TransferRequest<T>) {
        assert!(accepter_kiosk.has_item(item_id), EItemNotFound);
        let mut offer = kiosk_extension::storage_mut(Ext {}, offerer_kiosk).remove<
            OfferKey<T>,
            Offer<T>,
        >(OfferKey<T> { offer: offer_id, item: item_id });
        let balance_value = offer.balance.value();
        let market_fee = offer.market_fee;
        let royalty_fee = offer.royalty_fee;

        let market_fee_coin = coin::take<SUI>(&mut offer.balance, market_fee, ctx);
        market.add_balance(market_fee_coin);

        let purchase_cap = accepter_kiosk.list_with_purchase_cap<T>(
            // 100 sui - 2 sui - unkown amount sui
            accepter_kiosk_cap,
            item_id,
            (balance_value - market_fee - royalty_fee),
            ctx,
        );
        let price_by_cap = purchase_cap.purchase_cap_min_price();

        let payment_coin = coin::take<SUI>(&mut offer.balance, price_by_cap, ctx);

        let (item, mut request) = accepter_kiosk.purchase_with_cap<T>(purchase_cap, payment_coin);

        if (royalty_fee > 0) {
            let royalty_fee = royalty_rule::fee_amount(policy, price_by_cap);
            let royalty_fee_coin = coin::take<SUI>(&mut offer.balance, royalty_fee, ctx);
            royalty_rule::pay<T>(policy, &mut request, royalty_fee_coin);
        };

        assert!(kiosk_extension::can_place<Ext>(offerer_kiosk), ECanNotPlaceToExtension);
        if (policy.has_rule<T, lock_rule::Rule>()) {
            kiosk_extension::lock(Ext {}, offerer_kiosk, item, policy);
            lock_rule::prove(&mut request, offerer_kiosk);
        } else {
            kiosk_extension::place(Ext {}, offerer_kiosk, item, policy);
        };
        if (policy.has_rule<T, floor_rule::Rule>()) {
            floor_rule::prove(policy, &mut request);
        };
        (OfferWrapper<T> { offer: offer }, request)
    }

    /// @dev Confirms the acceptance of an offer, emits an event, destroys the offer object, and refunds
    ///      any remaining balance to the offerer.
    /// @notice The `confirm_offer_accepted` function should be executed last to finalize the offer acceptance.
    ///         The `OfferWrapper` is a hotpotato and should be processed in `confirm_offer_accepted`.
    /// @param offer_wrapper A wrapper object containing the offer details.
    /// @param request The transfer request associated with the item.
    /// @param policy A reference to the transfer policy applied to the item.
    /// @param ctx The transaction context of the sender.
    public fun confirm_offer_accepted<T: key + store>(
        // offerer_kiosk: &mut Kiosk,
        offer_wrapper: OfferWrapper<T>,
        request: TransferRequest<T>,
        policy: &TransferPolicy<T>,
        ctx: &mut TxContext,
    ) {
        policy.confirm_request(request);

        let OfferWrapper { offer } = offer_wrapper;
        let offer_id = object::id(&offer);

        emit_accept_offer_event(
            offer.kiosk,
            offer_id,
            offer.item,
            offer.item_type,
            offer.price,
            offer.royalty_fee,
            offer.market_fee,
            offer.offer_cap,
        );

        // have to destroy offer object here
        // return back balance to offer owner
        let Offer {
            id,
            kiosk: _,
            owner,
            item: _,
            item_type: _,
            price: _,
            market_fee: _,
            royalty_fee: _,
            balance,
            offer_cap,
        } = offer;

        market_p::create_receipt<T>(offer_cap, owner, ctx);

        let mut remain_coin = coin::zero<SUI>(ctx);
        remain_coin.balance_mut().join(balance);
        transfer::public_transfer(remain_coin, owner);
        object::delete(id);

        // kiosk_extension::storage_mut(Ext{}, offerer_kiosk).add(OfferKey<T>{offer: object::id(&offer), item: offer.item}, offer);
    }

    /// @dev Declines an existing offer in the marketplace. This function removes the offer from
    ///      the kiosk's storage, refunds the offer's balance to the offerer, and emits a decline event.
    /// @param offerer_kiosk A mutable reference to the kiosk where the offer was stored.
    /// @param offer_id The ID of the offer being declined.
    /// @param item The item associated with the offer being declined.
    /// @param ctx The transaction context of the sender.
    public fun decline_offer<T: key + store>(
        offerer_kiosk: &mut Kiosk,
        offer_id: ID,
        item: &T,
        ctx: &mut TxContext,
    ) {
        let offer = kiosk_extension::storage_mut(Ext {}, offerer_kiosk).remove<
            OfferKey<T>,
            Offer<T>,
        >(OfferKey<T> { offer: offer_id, item: object::id(item) });

        let offer_id = object::id(&offer);

        let Offer {
            id,
            kiosk,
            owner,
            item,
            item_type,
            price,
            market_fee,
            royalty_fee,
            balance,
            offer_cap,
        } = offer;

        market_p::create_receipt<T>(offer_cap, owner, ctx);

        let mut coin = coin::zero<SUI>(ctx);

        emit_decline_offer_event(
            kiosk,
            offer_id,
            item,
            item_type,
            price,
            royalty_fee,
            market_fee,
            offer_cap,
        );

        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, owner);
        id.delete();
    }

    // ====================== Package Internal Functions ======================
    /// @dev Creates a new offer for an item in the marketplace. This function calculates
    ///      the market fee and royalty fee, ensures the payment covers all required fees, and
    ///      returns the created offer and its associated capability.
    /// @param kiosk A mutable reference to the kiosk where the offer will be listed.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param item_id The ID of the item being offered.
    /// @param price The price of the item (in mist unit).
    /// @param payment A Coin<SUI> object representing the payment for the offer.
    /// @param policy A reference to the transfer policy applied to the offer.
    /// @param market A reference to the marketplace.
    /// @param ctx The transaction context of the sender.
    /// @return A tuple containing the created `Offer<T>` and its associated `OfferCap<T>`.
    fun new_offer<T: key + store>(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap,
        item_id: ID,
        // price: u64,
        payment: Coin<SUI>,
        policy: &TransferPolicy<T>,
        market: &MarketPlace,
        ctx: &mut TxContext,
    ): (Offer<T>, OfferCap) {
        assert!(kiosk.has_access(kiosk_cap), 100);

        // 100 sui
        let balance = payment.into_balance();
        let value = balance.value();
        let market_fee =
            (((market.get_fee(ctx.sender()) as u128) * (value as u128)) / 10000) as u64; // 2 sui marketplace fee = 2 %

        let royalty_fee = if (policy.has_rule<T, RoyaltyRule>()) {
            let first_round = royalty_rule::fee_amount(policy, value - market_fee);
            let second_round = royalty_rule::fee_amount(policy, value - market_fee - first_round);
            royalty_rule::fee_amount(
                policy,
                value - market_fee - second_round,
            )
        } else {
            0
        };

        assert!(value >= market_fee + royalty_fee, EInsufficientAmount);

        let mut offer = Offer<T> {
            id: object::new(ctx),
            kiosk: object::id(kiosk),
            owner: tx_context::sender(ctx),
            item: item_id,
            item_type: utils::type_to_string<T>(),
            price: value,
            market_fee: market_fee,
            royalty_fee: royalty_fee,
            balance,
            offer_cap: item_id, // temporary value
        };
        let offer_cap = market_p::create_offer_cap<T>(offer.id.to_inner(), ctx);

        offer.offer_cap = object::id(&offer_cap);

        (offer, offer_cap)
    }

    // ====================== Emit Event Functions ======================

    /// @dev Emits an event when a new offer is created in the marketplace. This event contains
    ///      information about the offer, including the kiosk, offer ID, item, price, and associated fees.
    /// @param kiosk The ID of the kiosk where the offer is listed.
    /// @param offer_id The ID of the newly created offer.
    /// @param offer_cap The ID of the offer capability.
    /// @param item The ID of the item being offered.
    /// @param price The price of the item (in mist unit).
    /// @param royalty_fee The royalty fee associated with the offer.
    /// @param market_fee The market fee associated with the offer.
    public(package) fun emit_offer_event(
        kiosk: ID,
        offer_id: ID,
        offer_cap: ID,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    ) {
        emit(OfferEvent {
            kiosk,
            offer_id,
            offer_cap,
            item,
            item_type,
            price,
            royalty_fee,
            market_fee,
        });
    }

    /// @dev Emits an event when an offer is revoked in the marketplace. This event contains
    ///      information about the revoked offer, including the kiosk, offer ID, item, price, and associated fees.
    /// @param kiosk The ID of the kiosk where the offer was listed.
    /// @param offer_id The ID of the revoked offer.
    /// @param item The ID of the item being revoked.
    /// @param price The price of the item (in mist unit).
    /// @param royalty_fee The royalty fee associated with the revoked offer.
    /// @param market_fee The market fee associated with the revoked offer.
    public(package) fun emit_revoke_offer_event(
        kiosk: ID,
        offer_id: ID,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
    ) {
        emit(RevokeOfferEvent {
            kiosk,
            offer_id,
            item,
            item_type,
            price,
            royalty_fee,
            market_fee,
        });
    }

    /// @dev Emits an event when an offer is accepted in the marketplace. This event contains
    ///      information about the accepted offer, including the kiosk, offer ID, item, price, and associated fees.
    /// @param kiosk The ID of the kiosk where the offer was accepted.
    /// @param offer_id The ID of the accepted offer.
    /// @param item The ID of the item being accepted.
    /// @param price The price of the item (in mist unit).
    /// @param royalty_fee The royalty fee associated with the accepted offer.
    /// @param market_fee The market fee associated with the accepted offer.
    public(package) fun emit_accept_offer_event(
        kiosk: ID,
        offer_id: ID,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
        offer_cap: ID,
    ) {
        emit(AcceptOfferEvent {
            kiosk,
            offer_id,
            item,
            item_type,
            price,
            royalty_fee,
            market_fee,
            offer_cap,
        });
    }

    /// @dev Emits an event when an offer is declined in the marketplace. This event contains
    ///      information about the declined offer, including the kiosk, offer ID, item, price, and associated fees.
    /// @param kiosk The ID of the kiosk where the offer was declined.
    /// @param offer_id The ID of the declined offer.
    /// @param item The ID of the item being declined.
    /// @param price The price of the item (in mist unit).
    /// @param royalty_fee The royalty fee associated with the declined offer.
    /// @param market_fee The market fee associated with the declined offer.
    public(package) fun emit_decline_offer_event(
        kiosk: ID,
        offer_id: ID,
        item: ID,
        item_type: String,
        price: u64,
        royalty_fee: u64,
        market_fee: u64,
        offer_cap: ID,
    ) {
        emit(DeclineOfferEvent {
            kiosk,
            offer_id,
            item,
            item_type,
            price,
            royalty_fee,
            market_fee,
            offer_cap,
        });
    }

    // ====================== Test ======================
    /// @dev Returns the offer ID from an `OfferEvent`. This function is used for retrieving
    ///      the unique identifier of an offer from an event to test.
    /// @param event A reference to the `OfferEvent` object containing the offer details.
    /// @return The ID of the offer from the event.
    #[test_only]
    public fun offer_event_id(event: &OfferEvent): ID {
        event.offer_id
    }
}
