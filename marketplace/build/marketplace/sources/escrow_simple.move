module marketplace::escrow_simple {
    use marketplace::{escrow, marketplace::{Self as market_p, MarketPlace, OfferCap}, utils};
    use std::string::String;
    use sui::{balance::Balance, coin::{Self, Coin}, sui::SUI};

    // ====================== Errors ======================
    const EInsufficientAmount: u64 = 411;

    // ====================== Constants ======================

    // ====================== Structs ======================

    public struct Offer<phantom T: key + store> has key, store {
        id: UID,
        owner: address,
        item: ID,
        item_type: String,
        price: u64,
        market_fee: u64,
        balance: Balance<SUI>,
        offer_cap: ID,
    }

    public struct OfferKey<phantom T: key + store> has copy, drop, store {
        offer: ID,
        item: ID,
    }

    // ====================== Public Functions ======================

    /// @dev Creates a new offer for an item in the marketplace, emits an event for the offer,
    ///      stores the offer in the marketplace, and transfers the offer capability to the offerer.
    /// @param market A mutable reference to the marketplace where the offer is being listed.
    /// @param item_id The ID of the item being offered.
    /// @param price The price of the item (in mist unit).
    /// @param payment A Coin<SUI> object representing the payment for the offer.
    /// @param ctx The transaction context of the sender.
    #[allow(lint(self_transfer))]
    public fun offer<T: key + store>(
        market: &mut MarketPlace,
        item_id: ID,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ) {
        let (offer, offer_cap) = new_offer<T>(
            market,
            item_id,
            payment,
            ctx,
        );
        let offer_id = object::id(&offer);
        let offer_cap_id = object::id(&offer_cap);

        escrow::emit_offer_event(
            object::id(market),
            offer_id,
            offer_cap_id,
            offer.item,
            offer.item_type,
            offer.price,
            0,
            offer.market_fee,
        );

        offer_cap.transfer_offer_cap(ctx);
        market.add_to_marketplace(OfferKey<T> { offer: object::id(&offer), item: item_id }, offer);
    }

    /// @dev Revokes an existing offer in the marketplace, removes it from the marketplace,
    ///      emits a revoke event, and transfers the remaining balance to the offer's owner.
    /// @param market A mutable reference to the marketplace where the offer is being revoked.
    /// @param offer_id The ID of the offer to be revoked.
    /// @param item_id The ID of the item being revoked.
    /// @param offer_cap The offer capability object associated with the offer.
    /// @param ctx The transaction context of the sender.
    #[allow(lint(self_transfer))]
    public fun revoke_offer<T: key + store>(
        market: &mut MarketPlace,
        offer_id: ID,
        item_id: ID,
        offer_cap: OfferCap,
        ctx: &mut TxContext,
    ) {
        offer_cap.assert_offer_match(offer_id);

        let offer = market.remove_from_marketplace(OfferKey<T> { offer: offer_id, item: item_id });

        let offer_id = object::id(&offer);
        let Offer<T> { id, owner: _, item, item_type, price, market_fee, balance, offer_cap: _ } =
            offer;
        object::delete(id);
        offer_cap.delete_cap();

        escrow::emit_revoke_offer_event(
            object::id(market),
            offer_id,
            item,
            item_type,
            price,
            0,
            market_fee,
        );

        let mut coin = coin::zero(ctx);
        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, tx_context::sender(ctx));
    }

    /// @dev Accepts an offer in the marketplace, transfers the item, pays the market fee,
    ///      and returns the remaining balance to the offer owner.
    /// @param market A mutable reference to the marketplace where the offer is being accepted.
    /// @param offer_id The ID of the offer being accepted.
    /// @param item The item being transferred as part of the offer.
    /// @param ctx The transaction context of the sender.
    #[allow(lint(self_transfer))]
    public fun accept_offer<T: key + store>(
        market: &mut MarketPlace,
        offer_id: ID,
        item: T,
        ctx: &mut TxContext,
    ) {
        let mut offer = market.remove_from_marketplace<OfferKey<T>, Offer<T>>(OfferKey<T> {
            offer: offer_id,
            item: object::id(&item),
        });

        let market_fee = offer.market_fee;
        let item_price = offer.price;

        let market_fee_coin = coin::take<SUI>(&mut offer.balance, market_fee, ctx);
        market.add_balance(market_fee_coin);

        let item_price_coin = coin::take<SUI>(&mut offer.balance, item_price, ctx);
        transfer::public_transfer(item_price_coin, tx_context::sender(ctx));
        transfer::public_transfer(item, offer.owner);

        let Offer { id, owner, item, item_type, price, market_fee: _, balance, offer_cap } = offer;

        // transfer::transfer(Receipt<T> { id: object::new(ctx), offer_cap }, owner);
        market_p::create_receipt<T>(offer_cap, owner, ctx);

        let mut remain_coin = coin::zero<SUI>(ctx);
        remain_coin.balance_mut().join(balance);
        transfer::public_transfer(remain_coin, ctx.sender());
        object::delete(id);

        escrow::emit_accept_offer_event(
            object::id(market),
            offer_id,
            item,
            item_type,
            price,
            0,
            market_fee,
            offer_cap,
        );
    }

    /// @dev Declines an offer in the marketplace, removes it, and transfers the remaining balance
    ///      back to the offer owner. Emits a decline event.
    /// @param market A mutable reference to the marketplace where the offer is being declined.
    /// @param offer_id The ID of the offer being declined.
    /// @param item The item associated with the declined offer.
    /// @param ctx The transaction context of the sender.
    public fun decline_offer<T: key + store>(
        market: &mut MarketPlace,
        offer_id: ID,
        item: &T,
        ctx: &mut TxContext,
    ) {
        let offer = market.remove_from_marketplace<OfferKey<T>, Offer<T>>(OfferKey<T> {
            offer: offer_id,
            item: object::id(item),
        });
        let offer_id = object::id(&offer);

        let Offer { id, owner, item: _, item_type, price, market_fee, balance, offer_cap } = offer;

        market_p::create_receipt<T>(offer_cap, owner, ctx);
        escrow::emit_decline_offer_event(
            object::id(market),
            offer_id,
            object::id(item),
            item_type,
            price,
            0,
            market_fee,
            offer_cap,
        );

        let mut coin = coin::zero<SUI>(ctx);
        coin.balance_mut().join(balance);
        transfer::public_transfer(coin, owner);
        object::delete(id);
    }

    // ====================== Package Internal Functions ======================
    /// @dev Creates a new offer in the marketplace with a specified price and payment amount.
    ///      It calculates the market fee based on the price and payment, then returns the created offer and offer cap.
    /// @param market A mutable reference to the marketplace where the offer is being created.
    /// @param item_id The ID of the item being offered.
    /// @param price The price of the item (in mist unit).
    /// @param payment The payment (in SUI) for the offer, which includes the price and market fee.
    /// @param ctx The transaction context of the sender.
    fun new_offer<T: key + store>(
        market: &MarketPlace,
        item_id: ID,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ): (Offer<T>, OfferCap) {
        let balance = payment.into_balance();
        let value = balance.value();
        let market_fee =
            (((market.get_fee(ctx.sender()) as u128) * (value as u128)) / 10000) as u64;

        assert!(value >=  market_fee, EInsufficientAmount);

        let mut offer = Offer<T> {
            id: object::new(ctx),
            owner: tx_context::sender(ctx),
            item: item_id,
            item_type: utils::type_to_string<T>(),
            price: value,
            market_fee: market_fee,
            balance,
            offer_cap: item_id, // Tepmorary value
        };
        // let offer_cap = OfferCap<T> {
        //     id: object::new(ctx),
        //     offer: object::id(&offer),
        // };
        let offer_cap = market_p::create_offer_cap<T>(offer.id.to_inner(), ctx);

        offer.offer_cap = object::id(&offer_cap);

        (offer, offer_cap)
    }
}
