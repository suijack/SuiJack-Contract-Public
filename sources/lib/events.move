module suijack::events {

  use sui::object::ID;
  use sui::event::emit;

  friend suijack::blackjack;

  /// Event for house withdraw
  struct HouseWithdraw<phantom T> has copy, store, drop {
    amount: u64,
  }

  public(friend) fun emit_house_withdraw<T>(amount: u64) {
    emit(HouseWithdraw<T> {
      amount,
    });
  }

  /// Event for house deposit
  struct HouseDeposit<phantom T> has copy, store, drop {
    amount: u64,
    depositor: address,
  }

  public(friend) fun emit_house_deposit<T>(
    amount: u64,
    depositor: address,
  ) {
    emit(HouseDeposit<T> {
      amount,
      depositor,
    });
  }

  /// Event for placed bets
  struct PlaceBet<phantom T> has copy, store, drop {
    bet_id: ID,
    bet_amount: u64,
    player: address,
  }

  public(friend) fun emit_place_bet<T>(
    bet_id: ID,
    bet_amount: u64,
    player: address,
  ) {
    emit(PlaceBet<T> {
      bet_id,
      bet_amount,
      player,
    });
  }

  /// Event for game create
  struct GameCreated<phantom T> has copy, store, drop {
    game_id: ID,
  }

  public(friend) fun emit_game_created<T>(
    game_id: ID,
  ) {
    emit(GameCreated<T> {
      game_id,
    });
  }

  /// Event for draw card
  struct CardDrawn<phantom T> has copy, store, drop {
    game_id: ID,
    game_round: u64,
    player_type: u8,
    card: u8,
    score: u8,
  }

  public(friend) fun emit_card_drawn<T>(
    game_id: ID,
    game_round: u64,
    player_type: u8,
    card: u8,
    score: u8,
  ) {
    emit(CardDrawn<T> {
      game_id,
      game_round,
      player_type,
      card,
      score,
    });
  }

  /// Event for player hand
  struct PlayerHand has copy, store, drop {
    game_id: ID,
    player_hand: vector<u8>,
    split_hand: vector<u8>,
  }

  public(friend) fun emit_player_hand(
    game_id: ID,
    player_hand: vector<u8>,
    split_hand: vector<u8>,
  ) {
    emit(PlayerHand {
      game_id,
      player_hand,
      split_hand,
    });
  }

  /// Event for game stage change
  struct StageChanged has copy, store, drop {
    game_id: ID,
    game_round: u64,
    stage: u8,
  }

  public(friend) fun emit_stage_changed(
    game_id: ID,
    game_round: u64,
    stage: u8,
  ) {
    emit(StageChanged {
      game_id,
      game_round,
      stage,
    });
  }

  /// Event for game result
  struct GameResult has copy, store, drop {
    game_id: ID,
    game_round: u64,
    player: address,
    payout: u64,
    income: u64,
    player_score: u8,
    split_player_score: u8,
    dealer_score: u8,
  }

  public(friend) fun emit_game_result(
    game_id: ID,
    game_round: u64,
    player: address,
    payout: u64,
    income: u64,
    player_score: u8,
    split_player_score: u8,
    dealer_score: u8,
  ) {
    emit(GameResult {
      game_id,
      game_round,
      player,
      payout,
      income,
      player_score,
      split_player_score,
      dealer_score,
    });
  }

  /// Event for split
  struct SplitBet<phantom T> has copy, store, drop {
    game_id: ID,
    game_round: u64,
    bet_amount: u64,
    player: address,
  }

  public(friend) fun emit_split_bet<T>(
    game_id: ID,
    game_round: u64,
    bet_amount: u64,
    player: address,
  ) {
    emit(SplitBet<T> {
      game_id,
      game_round,
      bet_amount,
      player,
    });
  }

  /// Event for double down
  struct DoubleDownBet<phantom T> has copy, store, drop {
    game_id: ID,
    game_round: u64,
    bet_amount: u64,
    player: address,
  }

  public(friend) fun emit_double_down_bet<T>(
    game_id: ID,
    game_round: u64,
    bet_amount: u64,
    player: address,
  ) {
    emit(DoubleDownBet<T> {
      game_id,
      game_round,
      bet_amount,
      player,
    });
  }

  /// Event for insurance
  struct InsuranceBet<phantom T> has copy, store, drop {
    game_id: ID,
    game_round: u64,
    bet_amount: u64,
    player: address,
  }

  public(friend) fun emit_insurance_bet<T>(
    game_id: ID,
    game_round: u64,
    bet_amount: u64,
    player: address,
  ) {
    emit(InsuranceBet<T> {
      game_id,
      game_round,
      bet_amount,
      player,
    });
  }

  /// Event for surrender
  struct Surrender<phantom T> has copy, store, drop {
    game_id: ID,
    game_round: u64,
    pay_amount: u64,
    player: address,
  }

  public(friend) fun emit_surrender<T>(
    game_id: ID,
    game_round: u64,
    pay_amount: u64,
    player: address,
  ) {
    emit(Surrender<T> {
      game_id,
      game_round,
      pay_amount,
      player,
    });
  }
}
