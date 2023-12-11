/// A sui based implementation of blackjack
module suijack::blackjack {

  use std::vector;
  use std::hash::sha2_256;

  use sui::object::{Self, UID, ID};
  use sui::balance::{Self, Balance};
  use sui::transfer;
  use sui::coin::{Self, Coin};
  use sui::tx_context::{Self, TxContext};
  use sui::table_vec::{Self as tvec, TableVec};
  use sui::clock::{Self, Clock};
  use sui::dynamic_object_field as dof;

  use suijack::bcs;
  use suijack::math;
  use suijack::events;
  use suijack::drand_lib::{derive_randomness, verify_drand_signature, safe_selection};

  /// Error codes
  const EInvalidPrivilege: u64 = 0;
  const EInsufficientHouseBalance: u64 = 1;
  const EInvalidGameStage: u64 = 2;
  const EInvalidBetAmount: u64 = 3;
  const EInvalidSplitHand: u64 = 4;
  const EInvalidSplitHit: u64 = 5;
  const EInvalidDoubleDown: u64 = 6;
  const EInvalidInsurance: u64 = 7;
  const EInvalidSurrender: u64 = 8;
  const EInvalidPayout: u64 = 9;
  const EGameNotFound: u64 = 10;

  /// Game stage
  const GS_BET: u8 = 0;
  const GS_PLAY_HAND: u8 = 1;
  const GS_PLAY_SPLIT_HAND: u8 = 2;
  const GS_CONCLUDE_HANDS: u8 = 3;

  /// Game constant parameters
  const BLACKJACK_TIMES: u64 = 1_500_000_000;
  const INSURANCE_TIMES: u64 = 2_000_000_000;
  const SURRENDER_TIMES: u64 = 500_000_000;
  const NUMBER_OF_DECKS: u8 = 1;
  const CARD_VALUES: vector<u8> = vector[11, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 10, 10];

  /// Win flag
  const WF_LOSE: u8 = 0;
  const WF_TIE: u8 = 1;
  const WF_WIN: u8 = 2;

  /// Event
  const PT_DEALER: u8 = 0;
  const PT_PLAYER: u8 = 1;
  const PT_SPLIT: u8 = 2;

  // ------------------------------ Structure ------------------------------

  struct HouseCap has key {
    id: UID,
    privilege: u8,
    house_id: ID,
  }

  struct HouseData<phantom Asset> has key {
    id: UID,
    balance: Balance<Asset>,
    house: address,
    house_risk: u64,
    round: u64,
    min_bet: u64,
    max_bet: u64,
    seed: u256,
    pending: vector<ID>,
  }

  struct Bet<phantom Asset> has key, store {
    id: UID,
    bet_size: Balance<Asset>,
    player: address,
  }

  struct Player<phantom Asset> has key, store {
    id: UID,
    bet_size_value: u64,
    double_down_bet: u64,
    insurance_bet: u64,
    seed: u256,
    score: u8,
    hand: vector<u8>,
    bets: TableVec<Bet<Asset>>,
  }

  struct Game<phantom Asset> has key, store {
    id: UID,
    owner: address,
    start_time: u64,
    round: u64,
    stage: u8,
    total_risk: u64,
    dealer: Player<Asset>,
    player: Player<Asset>,
    split_player: Player<Asset>,
  }

  // ------------------------------ Public Accessors ------------------------------

  /// Returns the balance of the house
  /// @param house_data: The HouseData object
  public fun balance<Asset>(house_data: &HouseData<Asset>): u64 {
    balance::value(&house_data.balance)
  }

  public fun house_risk<Asset>(house_data: &HouseData<Asset>): u64 {
    house_data.house_risk
  }

  public fun house_id<Asset>(house_data: &HouseData<Asset>): ID {
    *object::uid_as_inner(&house_data.id)
  }

  public fun house_pending_length<Asset>(house_data: &HouseData<Asset>): u64 {
    vector::length(&house_data.pending)
  }

  public fun game_risk<Asset>(house_data: &HouseData<Asset>, game_id: ID): u64 {
    let game = borrow_game(house_data, game_id);
    game.total_risk
  }

  public fun borrow_game<Asset>(house_data: &HouseData<Asset>, game_id: ID): &Game<Asset> {
    assert!(dof::exists_with_type<ID, Game<Asset>>(&house_data.id, game_id), EGameNotFound);
    dof::borrow<ID, Game<Asset>>(&house_data.id, game_id)
  }

  public fun id_zero(): ID {
    object::id_from_address(@0x0)
  }

  public fun id_is_zero(id: &ID): bool {
    *id == id_zero()
  }

  // ------------------------------ Private Functions ------------------------------
  
  /// Constructor
  fun init(ctx: &mut TxContext) {
    transfer::transfer(HouseCap {
      id: object::new(ctx),
      privilege: 0,
      house_id: id_zero(),
    }, tx_context::sender(ctx))
  }

  fun card_length(hand: &vector<u8>): u64 {
    vector::length(hand)
  }

  fun card_number(hand: &vector<u8>, card_index: u64): u8 {
    *vector::borrow(hand, card_index)
  }

  fun card_score_index(hand: &vector<u8>, card_index: u64): u64 {
    ((card_number(hand, card_index) as u64) % 13)
  }

  fun card_score(hand: &vector<u8>, card_index: u64): u8 {
    let card = card_score_index(hand, card_index);
    *vector::borrow(&CARD_VALUES, card)
  }

  fun recalculate(hand: &vector<u8>): u8 {
    let score: u8 = 0;
    let num_of_aces: u8 = 0;
    let card_length: u64 = card_length(hand);
    let card_index: u64 = 0;
    while (card_index < card_length) {
      score = score + card_score(hand, card_index);
      if (card_score_index(hand, card_index) == 0) {
        num_of_aces = num_of_aces + 1;
      };
      card_index = card_index + 1;
    };
    while (num_of_aces > 0 && score > 21) {
      score = score - 10;
      num_of_aces = num_of_aces - 1;
    };
    score
  }

  fun draw_card<Asset>(
    seed: &mut u256,
    game_id: ID,
    game_round: u64,
    player: &mut Player<Asset>,
    player_type: u8,
    random: u256,
  ) {
    let card = ((player.seed ^ *seed) + random) % ((NUMBER_OF_DECKS * 52) as u256);
    player.seed = bcs::deserialize(&sha2_256(bcs::serialize(player.seed, card, random)));
    *seed = bcs::deserialize(&sha2_256(bcs::serialize(*seed, card, random)));
    vector::push_back(&mut player.hand, (card as u8));
    player.score = recalculate(&player.hand);
    std::debug::print(&card_score(&player.hand, card_length(&player.hand) - 1));
    events::emit_card_drawn<Asset>(game_id, game_round, player_type, (card as u8), player.score);
  }

  fun deal_cards<Asset>(seed: &mut u256, game: &mut Game<Asset>, clock: &Clock) {
    let game_id = *object::uid_as_inner(&game.id);
    let now: u256 = (clock::timestamp_ms(clock) as u256);
    draw_card(seed, game_id, game.round, &mut game.player, PT_PLAYER, now);
    draw_card(seed, game_id, game.round, &mut game.dealer, PT_DEALER, now);
    draw_card(seed, game_id, game.round, &mut game.player, PT_PLAYER, now);
  }

  fun next_stage<Asset>(game: &mut Game<Asset>) {
    assert!(game.stage < GS_CONCLUDE_HANDS, EInvalidGameStage);
    game.stage = game.stage + 1;
    if (game.stage == GS_PLAY_SPLIT_HAND && game.split_player.bet_size_value == 0) {
      game.stage = game.stage + 1;
    };
    let game_id = *object::uid_as_inner(&game.id);
    events::emit_stage_changed(game_id, game.round, game.stage);
  }

  fun borrow_game_mut<Asset>(house_data: &mut HouseData<Asset>, game_id: ID): &mut Game<Asset> {
    assert!(dof::exists_with_type<ID, Game<Asset>>(&house_data.id, game_id), EGameNotFound);
    dof::borrow_mut<ID, Game<Asset>>(&mut house_data.id, game_id)
  }

  fun delete_player<Asset>(player: Player<Asset>) {
    let Player {
      id,
      bet_size_value: _,
      double_down_bet: _,
      insurance_bet: _,
      seed: _,
      score: _,
      hand,
      bets,
    } = player;
    object::delete(id);
    while (card_length(&hand) > 0) {
      vector::pop_back(&mut hand);
    };
    vector::destroy_empty(hand);
    tvec::destroy_empty(bets);
  }

  fun delete_game<Asset>(game: Game<Asset>) {
    std::debug::print(&game);
    let Game {
      id,
      owner: _,
      start_time: _,
      round: _,
      stage: _,
      total_risk: _,
      dealer,
      player,
      split_player,
    } = game;
    object::delete(id);
    delete_player(dealer);
    delete_player(player);
    delete_player(split_player);
  }

  fun player_has_bj<Asset>(player: &Player<Asset>): bool {
    (player.score == 21 && card_length(&player.hand) == 2)
  }

  /// Dealer rules H17
  /// @return bool Whether the dealer has Blackjack
  fun draw_dealer_cards<Asset>(game: &mut Game<Asset>, seed: &mut u256, random: u256): bool {
    let game_id = *object::uid_as_inner(&game.id);
    if (
      (game.player.score > 21 && game.split_player.bet_size_value == 0) ||
      (game.player.score > 21 && game.split_player.score > 21)
    ) {
      draw_card(seed, game_id, game.round, &mut game.dealer, PT_DEALER, random);
    } else {
      while (
        (game.dealer.score < 17) ||
        (game.dealer.score == 17) && (card_length(&game.dealer.hand) == 2) &&
        (card_score(&game.dealer.hand, 0) == 11 || card_score(&game.dealer.hand, 1) == 11)
      ) {
        draw_card(seed, game_id, game.round, &mut game.dealer, PT_DEALER, random);
      };
    };
    player_has_bj(&game.dealer)
  }

  /// @return u64 Payout amount, bool tie flag
  fun calculate_payout<Asset>(
    player: &Player<Asset>,
    dealer: &Player<Asset>,
    dealer_has_bj: bool,
    player_has_split: bool,
  ): (u64, bool) {
    let payout: u64 = 0;
    let tie = false;
    let player_has_bj = (player_has_bj(player) && !player_has_split);
    if (player_has_bj || dealer_has_bj) {
      if (player_has_bj && dealer_has_bj) {
        tie = true;
      } else if (player_has_bj) {
        payout = math::unsafe_mul(player.bet_size_value, BLACKJACK_TIMES);
      };
    } else if (player.score > dealer.score || dealer.score > 21) {
      payout = player.bet_size_value + player.double_down_bet;
    } else if (player.score == dealer.score) {
      tie = true;
    };
    (payout, tie)
  }

  fun get_coin<Asset>(bet: Bet<Asset>, ctx: &mut TxContext): (Coin<Asset>, address) {
    let Bet<Asset> { id, bet_size, player } = bet;
    let player_bet = balance::value(&bet_size);
    let player_coin = coin::take(&mut bet_size, player_bet, ctx);
    balance::destroy_zero(bet_size);
    object::delete(id);
    (player_coin, player)
  }

  fun payout_without_split<Asset>(
    house_balance: &mut Balance<Asset>,
    player_coin: Coin<Asset>,
    player_address: address,
    payout: u64,
    insurance: u64,
    dealer_has_bj: bool,
    player_wf: u8,
    ctx: &mut TxContext
  ): (u64, u64) {
    let income: u64 = 0;
    let insurance_payout: u64 = 0;
    if (insurance > 0) {
      let insurance_coin = coin::split(&mut player_coin, insurance, ctx);
      income = coin::value(&insurance_coin);
      coin::put(house_balance, insurance_coin);
      if (dealer_has_bj) {
        insurance_payout = math::unsafe_mul(insurance, INSURANCE_TIMES);
      };
    };
    if (payout > 0) {
      let house_payment = coin::take(house_balance, payout + insurance_payout, ctx);
      coin::join(&mut house_payment, player_coin);
      transfer::public_transfer(house_payment, player_address);
    } else if (player_wf == WF_TIE) {
      if (insurance_payout > 0) {
        let insurance_payment = coin::take(house_balance, insurance_payout, ctx);
        coin::join(&mut player_coin, insurance_payment);
      };
      transfer::public_transfer(player_coin, player_address);
    } else {
      if (insurance_payout > 0) {
        let insurance_payment = coin::take(house_balance, insurance_payout, ctx);
        transfer::public_transfer(insurance_payment, player_address);
      };
      income = income + coin::value(&player_coin);
      coin::put(house_balance, player_coin);
    };
    (income, insurance_payout)
  }

  fun payout_with_split<Asset>(
    house_balance: &mut Balance<Asset>,
    player_coin: Coin<Asset>,
    split_coin: Coin<Asset>,
    player_address: address,
    payout: u64,
    insurance: u64,
    dealer_has_bj: bool,
    player_wf: u8,
    split_wf: u8,
    ctx: &mut TxContext
  ): (u64, u64) {
    let income: u64 = 0;
    let insurance_payout: u64 = 0;
    if (insurance > 0) {
      let insurance_coin = coin::split(&mut player_coin, insurance, ctx);
      income = coin::value(&insurance_coin);
      coin::put(house_balance, insurance_coin);
      if (dealer_has_bj) {
        insurance_payout = math::unsafe_mul(insurance, INSURANCE_TIMES);
      };
    };
    if (payout > 0) {
      let house_payment = coin::take(house_balance, payout + insurance_payout, ctx);
      if (player_wf > WF_LOSE) {
        coin::join(&mut house_payment, player_coin);
      } else {
        income = income + coin::value(&player_coin);
        coin::put(house_balance, player_coin);
      };
      if (split_wf > WF_LOSE) {
        coin::join(&mut house_payment, split_coin);
      } else {
        income = income + coin::value(&split_coin);
        coin::put(house_balance, split_coin);
      };
      transfer::public_transfer(house_payment, player_address);
    } else if (player_wf == WF_TIE) {
      if (insurance_payout > 0) {
        let insurance_payment = coin::take(house_balance, insurance_payout, ctx);
        coin::join(&mut player_coin, insurance_payment);
      };
      if (split_wf == WF_TIE) {
        coin::join(&mut player_coin, split_coin);
      } else {
        income = income + coin::value(&split_coin);
        coin::put(house_balance, split_coin);
      };
      transfer::public_transfer(player_coin, player_address);
    } else if (split_wf == WF_TIE) {
      if (insurance_payout > 0) {
        let insurance_payment = coin::take(house_balance, insurance_payout, ctx);
        coin::join(&mut split_coin, insurance_payment);
      };
      transfer::public_transfer(split_coin, player_address);
      income = income + coin::value(&player_coin);
      coin::put(house_balance, player_coin);
    } else {
      if (insurance_payout > 0) {
        let insurance_payment = coin::take(house_balance, insurance_payout, ctx);
        transfer::public_transfer(insurance_payment, player_address);
      };
      income = income + coin::value(&player_coin);
      income = income + coin::value(&split_coin);
      coin::put(house_balance, player_coin);
      coin::put(house_balance, split_coin);
    };
    (income, insurance_payout)
  }

  fun conclude_game<Asset>(
    house_balance: &mut Balance<Asset>,
    game: &mut Game<Asset>,
    seed: &mut u256,
    random: u256,
    ctx: &mut TxContext
  ) {
    let payout: u64 = 0;
    let income: u64;
    let insurance_payout: u64;
    let player_wf = WF_LOSE;
    let split_wf = WF_LOSE;
    let dealer_has_bj: bool = draw_dealer_cards(game, seed, random);
    let player_has_split: bool = (game.split_player.bet_size_value > 0);
    if (game.player.score <= 21) {
      let (payout_, tie) = calculate_payout(&game.player, &game.dealer, dealer_has_bj, player_has_split);
      payout = payout + payout_;
      if (payout_ > 0) {
        player_wf = WF_WIN;
      } else if (tie) {
        player_wf = WF_TIE;
      }
    };
    let (player_coin, player_address) = get_coin(tvec::pop_back(&mut game.player.bets), ctx);
    if (player_has_split) {
      if (game.split_player.score <= 21) {
        let (payout_, tie) = calculate_payout(&game.split_player, &game.dealer, dealer_has_bj, player_has_split);
        payout = payout + payout_;
        if (payout_ > 0) {
          split_wf = WF_WIN;
        } else if (tie) {
          split_wf = WF_TIE;
        }
      };
      // 2 hands * blackjack = 3 bets max
      assert!(payout <= math::unsafe_mul(game.player.bet_size_value, 3_000_000_000), EInvalidPayout);
      let (split_coin, _) = get_coin(tvec::pop_back(&mut game.split_player.bets), ctx);
      (income, insurance_payout) = payout_with_split(
        house_balance,
        player_coin,
        split_coin,
        player_address,
        payout,
        game.player.insurance_bet,
        dealer_has_bj,
        player_wf,
        split_wf,
        ctx
      );
    } else {
      // double down = 2 bets max
      assert!(payout <= math::unsafe_mul(game.player.bet_size_value, 2_000_000_000), EInvalidPayout);
      (income, insurance_payout) = payout_without_split(
        house_balance,
        player_coin,
        player_address,
        payout,
        game.player.insurance_bet,
        dealer_has_bj,
        player_wf,
        ctx
      );
    };
    let game_id = *object::uid_as_inner(&game.id);
    events::emit_game_result(
      game_id,
      game.round,
      player_address,
      (payout + insurance_payout),
      income,
      game.player.score,
      game.split_player.score,
      game.dealer.score
    );
  }

  fun surrender_game<Asset>(
    house_balance: &mut Balance<Asset>,
    game: &mut Game<Asset>,
    seed: &mut u256,
    random: u256,
    ctx: &mut TxContext
  ) {
    draw_dealer_cards(game, seed, random);
    let (player_coin, player_address) = get_coin(tvec::pop_back(&mut game.player.bets), ctx);
    let surrender_payout = math::unsafe_mul(game.player.bet_size_value, SURRENDER_TIMES);
    let surrender_payment = coin::split(&mut player_coin, surrender_payout, ctx);
    let game_id = *object::uid_as_inner(&game.id);
    events::emit_surrender<Asset>(game_id, game.round, surrender_payout, player_address);
    transfer::public_transfer(surrender_payment, player_address);
    let income = coin::value(&player_coin);
    coin::put(house_balance, player_coin);
    events::emit_game_result(
      game_id,
      game.round,
      player_address,
      0,
      income,
      game.player.score,
      game.split_player.score,
      game.dealer.score
    );
  }

  fun reduce_risk(house_risk: u64, risk: u64): u64 {
    if (house_risk > risk) {
      house_risk - risk
    } else {
      0
    }
  }

  fun is_house_mgr<Asset>(
    house_cap: &HouseCap,
    house_data: &HouseData<Asset>,
  ): bool {
    (house_cap.privilege == 0) || 
    (house_cap.privilege == 1 && house_cap.house_id == house_id<Asset>(house_data))
  }

  fun is_game_mgr<Asset>(
    house_cap: &HouseCap,
    house_data: &HouseData<Asset>,
  ): bool {
    (house_cap.privilege == 0) ||
    (house_cap.privilege <= 2 && house_cap.house_id == house_id<Asset>(house_data))
  }

  // ------------------------------ Entry Functions ------------------------------

  /// Create a HouseCap for the address.
  public entry fun create_house_cap(
    house_cap: &HouseCap,
    privilege: u8,
    house_id: ID,
    manager: address,
    ctx: &mut TxContext
  ) {
    assert!(house_cap.privilege == 0, EInvalidPrivilege);
    transfer::transfer(HouseCap {
      id: object::new(ctx),
      privilege: privilege,
      house_id: house_id,
    }, manager)
  }

  /// Initializes the house data object.
  public entry fun initialize_house_data<Asset>(
    house_cap: &mut HouseCap,
    house_address: address,
    clock: &Clock,
    ctx: &mut TxContext
  ) {
    assert!(
      (house_cap.privilege == 0) ||
      (house_cap.privilege == 1 && id_is_zero(&house_cap.house_id)),
      EInvalidPrivilege
    );
    let house_data = HouseData<Asset> {
      id: object::new(ctx),
      balance: balance::zero(),
      house: house_address,
      house_risk: 0,
      round: 0,
      min_bet: 1000000000,          // 1 SUI
      max_bet: 50 * 1000000000,    // 400 SUI
      seed: (clock::timestamp_ms(clock) as u256),
      pending: vector::empty(),
    };
    if (house_cap.privilege == 1) {
      house_cap.house_id = house_id<Asset>(&house_data);
    };
    transfer::share_object(house_data);
  }

  /// Change the house owner 
  // public entry fun set_house_owner<Asset>(
  //   house_cap: &HouseCap,
  //   house_data: &mut HouseData<Asset>,
  //   ctx: &TxContext
  // ) {
  //   assert!(is_house_mgr(house_cap, house_data), EInvalidPrivilege);
  //   house_data.house = tx_context::sender(ctx);
  // }

  /// Change the minimum bet amount
  public entry fun set_house_min_bet<Asset>(
    house_cap: &HouseCap,
    house_data: &mut HouseData<Asset>,
    min_bet: u64
  ) {
    assert!(is_house_mgr(house_cap, house_data), EInvalidPrivilege);
    house_data.min_bet = min_bet;
  }

  /// Change the maximum bet amount
  public entry fun set_house_max_bet<Asset>(
    house_cap: &HouseCap,
    house_data: &mut HouseData<Asset>,
    max_bet: u64
  ) {
    assert!(is_house_mgr(house_cap, house_data), EInvalidPrivilege);
    house_data.max_bet = max_bet;
  }

  /// House can withdraw the entire balance of the house object
  public entry fun withdraw<Asset>(
    house_data: &mut HouseData<Asset>,
    quantity: u64,
    ctx: &mut TxContext
  ) {
    assert!((tx_context::sender(ctx) == house_data.house), EInvalidPrivilege);
    events::emit_house_withdraw<Asset>(quantity);
    let coin = coin::take(&mut house_data.balance, quantity, ctx);
    transfer::public_transfer(coin, house_data.house);
  }

  /// Function used to top up the house balance. Can be called by anyone.
  public entry fun top_up<Asset>(
    house_data: &mut HouseData<Asset>,
    coin: Coin<Asset>,
    ctx: &TxContext
  ) {        
    let coin_value = coin::value(&coin);
    let coin_balance = coin::into_balance(coin);
    events::emit_house_deposit<Asset>(coin_value, tx_context::sender(ctx));
    balance::join(&mut house_data.balance, coin_balance);
  }

  /// Start a new round of Blackjack with the transferred value as the original bet.
  public entry fun new_round<Asset>(
    coin: Coin<Asset>,
    house_data: &mut HouseData<Asset>,
    clock: &Clock,
    ctx: &mut TxContext
  ): ID {
    // bet amount
    let coin_value = coin::value(&coin);
    assert!(coin_value >= house_data.min_bet && coin_value <= house_data.max_bet, EInvalidBetAmount);
    // house risk
    let risk_change = math::unsafe_mul(coin_value, BLACKJACK_TIMES);
    let total_risk = house_data.house_risk + risk_change;
    assert!(total_risk <= balance(house_data), EInsufficientHouseBalance);
    house_data.house_risk = total_risk;
    // create bet
    let bet = Bet {
      id: object::new(ctx),
      bet_size: coin::into_balance(coin),
      player: tx_context::sender(ctx),
    };
    // emit bet event
    let bet_balance_value = balance::value(&bet.bet_size);
    let bet_id = *object::uid_as_inner(&bet.id);
    events::emit_place_bet<Asset>(bet_id, bet_balance_value, bet.player);
    // get timestamp
    let timestamp = clock::timestamp_ms(clock);
    let r1 = (house_data.round as u256);
    let r2 = (timestamp as u256);
    // create dealer
    let seed = bcs::deserialize(&sha2_256(bcs::serialize(house_data.seed, r1, r2)));
    let dealer = Player<Asset> {
      id: object::new(ctx),
      bet_size_value: 0,
      double_down_bet: 0,
      insurance_bet: 0,
      seed: seed,
      score: 0,
      hand: vector::empty(),
      bets: tvec::empty(ctx),
    };
    // create player
    seed = bcs::deserialize(&sha2_256(bcs::serialize(seed, r1, r2)));
    let player = Player<Asset> {
      id: object::new(ctx),
      bet_size_value: balance::value(&bet.bet_size),
      double_down_bet: 0,
      insurance_bet: 0,
      seed: seed,
      score: 0,
      hand: vector::empty(),
      bets: tvec::empty(ctx),
    };
    tvec::push_back(&mut player.bets, bet);
    // create split player
    seed = bcs::deserialize(&sha2_256(bcs::serialize(seed, r1, r2)));
    let split_player = Player<Asset> {
      id: object::new(ctx),
      bet_size_value: 0,
      double_down_bet: 0,
      insurance_bet: 0,
      seed: seed,
      score: 0,
      hand: vector::empty(),
      bets: tvec::empty(ctx),
    };
    // create game
    house_data.seed = seed;
    house_data.round = house_data.round + 1;
    let game = Game<Asset> {
      id: object::new(ctx),
      owner: tx_context::sender(ctx),
      start_time: timestamp,
      round: house_data.round,
      stage: GS_BET,
      total_risk: total_risk,
      dealer: dealer,
      player: player,
      split_player: split_player,
    };
    let game_id = *object::uid_as_inner(&game.id);
    events::emit_game_created<Asset>(game_id);
    deal_cards(&mut house_data.seed, &mut game, clock);
    events::emit_player_hand(game_id, game.player.hand, vector::empty());
    next_stage(&mut game);
    std::debug::print(&game);
    dof::add(&mut house_data.id, game_id, game);
    game_id
  }

  /// Split first two cards into two hands.
  public entry fun split<Asset>(
    coin: Coin<Asset>,
    house_data: &mut HouseData<Asset>,
    game_id: ID,
    clock: &Clock,
    ctx: &mut TxContext
  ) {
    let coin_value = coin::value(&coin);
    let seed = house_data.seed;
    // house risk
    let risk_change = math::unsafe_mul(coin_value, BLACKJACK_TIMES);
    let total_risk = house_data.house_risk + risk_change;
    assert!(total_risk <= balance(house_data), EInsufficientHouseBalance);
    // validity check
    let sender = tx_context::sender(ctx);
    let game = borrow_game_mut(house_data, game_id);
    assert!(
      (game.owner == sender) &&
      (game.stage == GS_PLAY_HAND) &&
      (game.player.bet_size_value == coin_value) &&
      (game.player.double_down_bet == 0) &&
      (card_length(&game.player.hand) == 2) &&
      (game.split_player.bet_size_value == 0) &&
      (card_score(&game.player.hand, 0) == card_score(&game.player.hand, 1)),
      EInvalidSplitHand
    );
    // create bet
    let bet = Bet {
      id: object::new(ctx),
      bet_size: coin::into_balance(coin),
      player: sender,
    };
    let bet_balance_value = balance::value(&bet.bet_size);
    events::emit_split_bet<Asset>(game_id, game.round, bet_balance_value, bet.player);
    tvec::push_back(&mut game.split_player.bets, bet);
    game.split_player.bet_size_value = coin_value;
    // split cards
    vector::push_back(&mut game.split_player.hand, vector::pop_back(&mut game.player.hand));
    // draw cards
    let now: u256 = (clock::timestamp_ms(clock) as u256);
    draw_card(&mut seed, game_id, game.round, &mut game.player, PT_PLAYER, now);
    draw_card(&mut seed, game_id, game.round, &mut game.split_player, PT_SPLIT, now);
    events::emit_player_hand(game_id, game.player.hand, game.split_player.hand);
    game.total_risk = game.total_risk + risk_change;
    std::debug::print(game);
    house_data.house_risk = total_risk;
    house_data.seed = seed;
  }

  /// Double down on first two cards, taking one additional card and standing,
  /// with an opportunity to double original bet.
  public entry fun double_down<Asset>(
    coin: Coin<Asset>,
    house_data: &mut HouseData<Asset>,
    game_id: ID,
    clock: &Clock,
    ctx: &mut TxContext
  ) {
    let coin_value = coin::value(&coin);
    let seed = house_data.seed;
    // house risk
    let risk_change = math::unsafe_mul(coin_value, BLACKJACK_TIMES);
    let total_risk = house_data.house_risk + risk_change;
    assert!(total_risk <= balance(house_data), EInsufficientHouseBalance);
    // validity check
    let game = borrow_game_mut(house_data, game_id);
    assert!(
      (game.owner == tx_context::sender(ctx)) &&
      (game.stage == GS_PLAY_HAND) &&
      (game.player.bet_size_value == coin_value) &&
      (game.player.double_down_bet == 0) &&
      (game.player.score != 21) &&
      (card_length(&game.player.hand) == 2) &&
      (game.split_player.bet_size_value == 0),
      EInvalidDoubleDown
    );
    // handle bet coin
    let bet = tvec::borrow_mut(&mut game.player.bets, 0);
    let bet_size = coin::into_balance(coin);
    let bet_balance_value = balance::value(&bet_size);
    events::emit_double_down_bet<Asset>(game_id, game.round, bet_balance_value, bet.player);
    balance::join(&mut bet.bet_size, bet_size);
    game.player.double_down_bet = coin_value;
    // draw a card
    let now: u256 = (clock::timestamp_ms(clock) as u256);
    draw_card(&mut seed, game_id, game.round, &mut game.player, PT_PLAYER, now);
    // change game stage
    next_stage(game);
    assert!(game.stage == GS_CONCLUDE_HANDS, EInvalidGameStage);
    vector::push_back(&mut house_data.pending, game_id);
    house_data.seed = seed;
  }

  /// Purchase insurance for an additional half of the original bet amount
  public entry fun insurance<Asset>(
    coin: Coin<Asset>,
    house_data: &mut HouseData<Asset>,
    game_id: ID,
    ctx: &mut TxContext
  ) {
    let coin_value = coin::value(&coin);
    // house risk
    let risk_change = math::unsafe_mul(coin_value, INSURANCE_TIMES);
    let total_risk = house_data.house_risk + risk_change;
    assert!(total_risk <= balance(house_data), EInsufficientHouseBalance);
    // validity check
    let game = borrow_game_mut(house_data, game_id);
    assert!(
      (game.owner == tx_context::sender(ctx)) &&
      (game.stage == GS_PLAY_HAND) &&
      (game.player.bet_size_value == math::unsafe_mul(coin_value, INSURANCE_TIMES)) &&
      (game.player.double_down_bet == 0) &&
      (card_length(&game.player.hand) == 2) &&
      (game.split_player.bet_size_value == 0) &&
      (card_score(&game.dealer.hand, 0) == 11),
      EInvalidInsurance
    );
    // handle bet coin
    let bet = tvec::borrow_mut(&mut game.player.bets, 0);
    let bet_size = coin::into_balance(coin);
    let bet_balance_value = balance::value(&bet_size);
    events::emit_insurance_bet<Asset>(game_id, game.round, bet_balance_value, bet.player);
    balance::join(&mut bet.bet_size, bet_size);
    game.player.insurance_bet = coin_value;
    game.total_risk = game.total_risk + risk_change;
    house_data.house_risk = house_data.house_risk + risk_change;
  }

  /// Surrender to get back half of the original bet amount
  public entry fun surrender<Asset>(
    house_data: &mut HouseData<Asset>,
    game_id: ID,
    clock: &Clock,
    ctx: &mut TxContext
  ) {
    // validity check
    let game = borrow_game_mut(house_data, game_id);
    assert!(
      (game.owner == tx_context::sender(ctx)) &&
      (game.stage == GS_PLAY_HAND) &&
      (game.player.double_down_bet == 0) &&
      (game.player.insurance_bet == 0) &&
      (card_length(&game.player.hand) == 2) &&
      (game.split_player.bet_size_value == 0),
      EInvalidSurrender
    );
    let now: u256 = (clock::timestamp_ms(clock) as u256);
    let game_risk = game.total_risk;
    next_stage(game);
    assert!(game.stage == GS_CONCLUDE_HANDS, EInvalidGameStage);
    let game = dof::remove<ID, Game<Asset>>(&mut house_data.id, game_id);
    surrender_game(&mut house_data.balance, &mut game, &mut house_data.seed, now, ctx);
    delete_game(game);
    house_data.house_risk = reduce_risk(house_data.house_risk, game_risk);
  }

  /// Hit, taking one additional card on the current hand.
  public entry fun hit<Asset>(
    house_cap: &HouseCap,
    house_data: &mut HouseData<Asset>,
    game_id: ID,
    clock: &Clock,
    _ctx: &mut TxContext
  ) {
    assert!(is_game_mgr(house_cap, house_data), EInvalidPrivilege);
    let seed = house_data.seed;
    let game = borrow_game_mut(house_data, game_id);
    assert!(
      (game.stage == GS_PLAY_HAND) || (game.stage == GS_PLAY_SPLIT_HAND),
      EInvalidGameStage
    );
    let now: u256 = (clock::timestamp_ms(clock) as u256);
    let done: bool = false;
    if (game.split_player.bet_size_value > 0) {
      assert!(card_score(&game.player.hand, 0) != 11, EInvalidSplitHit);
    };
    if (game.stage == GS_PLAY_HAND) {
      assert!(game.player.score < 21, EInvalidGameStage);
      draw_card(&mut seed, game_id, game.round, &mut game.player, PT_PLAYER, now);
      if (game.player.score >= 21) {
        next_stage(game);
        done = (game.stage == GS_CONCLUDE_HANDS);
      };
    } else {  // split hand
      assert!(game.split_player.bet_size_value > 0, EInvalidSplitHand);
      assert!(game.split_player.score < 21, EInvalidGameStage);
      draw_card(&mut seed, game_id, game.round, &mut game.split_player, PT_SPLIT, now);
      if (game.split_player.score >= 21) {
        next_stage(game);
        done = (game.stage == GS_CONCLUDE_HANDS);
      };
    };
    if (done) {
      vector::push_back(&mut house_data.pending, game_id);
    };
    house_data.seed = seed;
  }

  /// Standing, taking no more additional cards and concluding the current hand.
  public entry fun stand<Asset>(
    house_cap: &HouseCap,
    house_data: &mut HouseData<Asset>,
    game_id: ID,
    _ctx: &mut TxContext
  ) {
    assert!(is_game_mgr(house_cap, house_data), EInvalidPrivilege);
    let game = borrow_game_mut(house_data, game_id);
    assert!(
      (game.stage == GS_PLAY_HAND) || (game.stage == GS_PLAY_SPLIT_HAND),
      EInvalidGameStage
    );
    next_stage(game);
    let done: bool = (game.stage == GS_CONCLUDE_HANDS);
    if (done) {
      vector::push_back(&mut house_data.pending, game_id);
    };
  }

  public entry fun settle<Asset>(
    house_cap: &HouseCap,
    house_data: &mut HouseData<Asset>,
    drand_round: u64,
    drand_sig: vector<u8>,
    drand_prev_sig: vector<u8>,
    max_settle: u64,
    clock: &Clock,
    ctx: &mut TxContext
  ) {
    assert!(is_game_mgr(house_cap, house_data), EInvalidPrivilege);
    verify_drand_signature(drand_sig, drand_prev_sig, drand_round);
    let digest = derive_randomness(drand_sig);
    let now = clock::timestamp_ms(clock);
    let random = (safe_selection(now, &digest) as u256);
    let total = vector::length(&house_data.pending);
    if (total > max_settle) {
      total = max_settle;
    };
    let index = 0;
    while (index < total) {
      let game_id = vector::pop_back(&mut house_data.pending);
      let game = dof::remove<ID, Game<Asset>>(&mut house_data.id, game_id);
      assert!(game.stage == GS_CONCLUDE_HANDS, EInvalidGameStage);
      let total_risk = game.total_risk;
      conclude_game(&mut house_data.balance, &mut game, &mut house_data.seed, random, ctx);
      delete_game(game);
      house_data.house_risk = reduce_risk(house_data.house_risk, total_risk);
      index = index + 1;
    };
  }

  // ------------------------------ For Test ------------------------------

  #[test_only]
  public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
  }

  #[test_only]
  public fun set_hands_for_testing<Asset>(
    house_data: &mut HouseData<Asset>,
    game_id: ID,
    dealer_hand: vector<u8>,
    player_hand: vector<u8>
  ) {
    let game = borrow_game_mut(house_data, game_id);
    game.dealer.hand = dealer_hand;
    game.player.hand = player_hand;
    game.dealer.score = recalculate(&game.dealer.hand);
    game.player.score = recalculate(&game.player.hand);
    std::debug::print(game);
  }
}
