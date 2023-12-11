# SuiJack-Contract-Public
SuiJack-Contract-Public

---
# Work Flow
1. Connect Wallet
2. Login(SignPersonalMessage to server)
3. `Bet`
    * Check Login
    * Check SUI balance
4. Call Contract(new_round)
> Player.seed =bcs::serialize(house_data.seed, house_data.round, timestamp)
>>DrawCard = ((Player.seed ^ HouseData.seed) + clock) % 52

5. Transaction Successed
6. Main page get Tx event show effect
7. Select Action
    * `Hit`
    * `Stand`
    * `Double`
    * `Surrender`
8. Call to Server Action
9. Server call contract
10. Main page get Tx event show effect
11. if pllayer action ended, contract add gameId to pending list
12. Every 3 seconds server get drand random seed call settle
13. Main page get Tx Event show effect