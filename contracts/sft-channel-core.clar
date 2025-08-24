;; sft-channel-core.clar
;; This contract serves as the central hub for the SFT Channel platform, handling
;; secure token trading, channel management, and participant interactions.
;; It provides a robust framework for creating and managing token-based channels
;; with configurable access and transaction rules.

;; ========== Error Constants ==========
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CHANNEL-NOT-FOUND (err u101))
(define-constant ERR-PARTICIPANT-ALREADY-EXISTS (err u102))
(define-constant ERR-PARTICIPANT-NOT-FOUND (err u103))
(define-constant ERR-CHANNEL-FULL (err u104))
(define-constant ERR-INSUFFICIENT-BALANCE (err u105))
(define-constant ERR-TRADE-NOT-ALLOWED (err u106))
(define-constant ERR-INVALID-TRADE-AMOUNT (err u107))
(define-constant ERR-CHANNEL-CLOSED (err u108))
(define-constant ERR-INVALID-PARAMETERS (err u109))
(define-constant ERR-NOT-CHANNEL-CREATOR (err u110))
(define-constant ERR-CHANNEL-ALREADY-EXISTS (err u111))

;; ========== Data Maps and Variables ==========

;; Trading channels - stores channel configuration and state
(define-map channels
  { channel-id: uint }
  {
    name: (string-utf8 100),
    description: (string-utf8 500),
    creator: principal,
    min-deposit: uint,
    max-channel-balance: uint,
    is-private: bool,
    active: bool
  }
)

;; Channel participants
(define-map channel-participants
  { channel-id: uint, participant: principal }
  {
    joined-at: uint,
    balance: uint,
    is-approved: bool
  }
)

;; Participant whitelists for private channels
(define-map channel-whitelist
  { channel-id: uint }
  {
    allowed-participants: (list 100 principal)
  }
)

;; Token trade records
(define-map token-trades
  { trade-id: uint }
  {
    channel-id: uint,
    sender: principal,
    recipient: principal,
    amount: uint,
    timestamp: uint,
    trade-details: (optional (string-utf8 200))
  }
)

;; Counters for generating unique IDs
(define-data-var channel-counter uint u0)
(define-data-var trade-counter uint u0)

;; ========== Private Functions ==========

;; Validate channel exists and is active
(define-private (is-channel-active (channel-id uint))
  (match (map-get? channels { channel-id: channel-id })
    channel (get active channel)
    false
  )
)

;; Record a token trade
(define-private (record-token-trade
  (channel-id uint)
  (sender principal)
  (recipient principal)
  (amount uint)
  (trade-details (optional (string-utf8 200)))
)
  (let
    (
      (new-trade-id (+ (var-get trade-counter) u1))
    )
    ;; Increment trade counter
    (var-set trade-counter new-trade-id)
    
    ;; Record the trade
    (map-set token-trades
      { trade-id: new-trade-id }
      {
        channel-id: channel-id,
        sender: sender,
        recipient: recipient,
        amount: amount,
        timestamp: block-height,
        trade-details: trade-details
      }
    )

    ;; Return the new trade ID
    new-trade-id
  )
)

;; Validate participant in channel
(define-private (is-valid-participant (channel-id uint) (participant principal))
  (match (map-get? channel-participants { channel-id: channel-id, participant: participant })
    participant-data (get is-approved participant-data)
    false
  )
)

;; ========== Read-Only Functions ==========

;; Get channel details
(define-read-only (get-channel-details (channel-id uint))
  (map-get? channels { channel-id: channel-id })
)

;; Get channel participant balance
(define-read-only (get-channel-balance (channel-id uint) (participant principal))
  (match (map-get? channel-participants { channel-id: channel-id, participant: participant })
    participant-data (get balance participant-data)
    u0
  )
)

;; Get trade details
(define-read-only (get-trade-details (trade-id uint))
  (map-get? token-trades { trade-id: trade-id })
)

;; ========== Public Functions ==========

;; Create a new trading channel
(define-public (create-channel 
  (name (string-utf8 100)) 
  (description (string-utf8 500))
  (min-deposit uint)
  (max-channel-balance uint)
  (is-private bool)
)
  (let
    (
      (sender tx-sender)
      (new-channel-id (+ (var-get channel-counter) u1))
    )
    ;; Validate parameters
    (asserts! (> min-deposit u0) ERR-INVALID-PARAMETERS)
    (asserts! (> max-channel-balance min-deposit) ERR-INVALID-PARAMETERS)
    
    ;; Increment channel counter
    (var-set channel-counter new-channel-id)
    
    ;; Create the channel
    (map-set channels
      { channel-id: new-channel-id }
      {
        name: name,
        description: description,
        creator: sender,
        min-deposit: min-deposit,
        max-channel-balance: max-channel-balance,
        is-private: is-private,
        active: true
      }
    )
    (ok new-channel-id)
  )
)

;; Add participant to a channel
(define-public (add-participant (channel-id uint) (participant principal))
  (let
    (
      (sender tx-sender)
      (channel (unwrap! (map-get? channels { channel-id: channel-id }) ERR-CHANNEL-NOT-FOUND))
    )
    ;; Check channel is active
    (asserts! (get active channel) ERR-CHANNEL-CLOSED)
    
    ;; If channel is private, ensure sender is the creator
    (asserts! 
      (or 
        (not (get is-private channel)) 
        (is-eq sender (get creator channel))
      ) 
      ERR-NOT-AUTHORIZED
    )
    
    ;; Add participant
    (map-set channel-participants
      { channel-id: channel-id, participant: participant }
      {
        joined-at: block-height,
        balance: u0,
        is-approved: true
      }
    )
    (ok true)
  )
)

;; Execute a token trade within a channel
(define-public (execute-trade 
  (channel-id uint)
  (sender principal)
  (recipient principal)
  (amount uint)
  (trade-details (optional (string-utf8 200)))
)
  (let
    (
      (current-sender tx-sender)
      (channel (unwrap! (map-get? channels { channel-id: channel-id }) ERR-CHANNEL-NOT-FOUND))
      (sender-balance (get-channel-balance channel-id sender))
      (recipient-balance (get-channel-balance channel-id recipient))
    )
    ;; Validate channel and participants
    (asserts! (get active channel) ERR-CHANNEL-CLOSED)
    (asserts! (is-valid-participant channel-id sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-valid-participant channel-id recipient) ERR-NOT-AUTHORIZED)
    
    ;; Validate trade amount
    (asserts! (> amount u0) ERR-INVALID-TRADE-AMOUNT)
    (asserts! (<= amount sender-balance) ERR-INSUFFICIENT-BALANCE)
    
    ;; Update balances
    (map-set channel-participants
      { channel-id: channel-id, participant: sender }
      {
        joined-at: block-height,
        balance: (- sender-balance amount),
        is-approved: true
      }
    )
    (map-set channel-participants
      { channel-id: channel-id, participant: recipient }
      {
        joined-at: block-height,
        balance: (+ recipient-balance amount),
        is-approved: true
      }
    )
    
    ;; Record the trade
    (let
      ((trade-id (record-token-trade channel-id sender recipient amount trade-details)))
      (ok trade-id)
    )
  )
)