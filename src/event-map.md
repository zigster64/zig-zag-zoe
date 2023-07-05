
# Game States

- (event-source) GET /game ... SSE link that returns the following event types

- init:  game is back to the start, wants params on grid size and number of players
- wait:  game is setup, is waiting for logins
- login: game is waiting for logins, a new player logged in
- start: everyone is logged in, the game has started
- next:  current player finished their turn, its the next player's turn
- victory: game has been won
- stalemate: game has ended in stalemate
- clock: a second has elapsed, clocks updated

## Init / Set Parameters

- GET /page .. Renders form to set the game parameters

## Game is setup, waiting for logins

- GET /page .. If user is logged in, shows a list of who is logged in, and who we are waiting on
        .. If user not logged in, shows a list of player slots available

## All players present, game is running

- GET /page .. Renders the game grid. If its your turn, has controls to add move

- PUT /move {x, y} .. places a peice on the board, and ends your turn -> event: next

- POST /restart .. restarts the game  -> event: start

## Game has ended in either Victory or Stalemate

- GET /page .. Renders the grid, and shows who won or if its a stalemate

- POST /restart .. restarts the game  -> event: start

- POST /newgame .. restarts the game from the very beginning -> event: init
