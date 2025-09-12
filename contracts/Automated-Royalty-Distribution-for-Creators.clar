(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-PERCENTAGE (err u101))
(define-constant ERR-ALREADY-LISTED (err u102))
(define-constant ERR-NOT-LISTED (err u103))
(define-constant ERR-WRONG-PRICE (err u104))
(define-constant ERR-NOT-OWNER (err u105))

(define-non-fungible-token artwork uint)

(define-map artwork-details
  { artwork-id: uint }
  {
    creator: principal,
    owner: principal,
    price: uint,
    royalty-percentage: uint,
    is-listed: bool
  }
)

(define-map creator-collaborators
  { artwork-id: uint }
  { collaborators: (list 10 { address: principal, share: uint }) }
)

(define-data-var artwork-nonce uint u0)
(define-data-var payment-nonce uint u0)
(define-data-var contract-paused bool false)

(define-map royalty-payments
  { payment-id: uint }
  {
    artwork-id: uint,
    recipient: principal,
    amount: uint,
    block-height: uint,
    transaction-sender: principal
  }
)

(define-map recipient-payment-history
  { recipient: principal, artwork-id: uint }
  { payment-ids: (list 50 uint), total-earned: uint }
)

(define-read-only (get-artwork-details (artwork-id uint))
  (map-get? artwork-details { artwork-id: artwork-id })
)

(define-read-only (get-collaborators (artwork-id uint))
  (map-get? creator-collaborators { artwork-id: artwork-id })
)

(define-read-only (get-royalty-payment (payment-id uint))
  (map-get? royalty-payments { payment-id: payment-id })
)

(define-read-only (get-recipient-history (recipient principal) (artwork-id uint))
  (map-get? recipient-payment-history { recipient: recipient, artwork-id: artwork-id })
)

(define-public (mint-artwork (royalty-percentage uint) (price uint) (collaborators (list 10 { address: principal, share: uint })))
  (let 
    (
      (artwork-id (+ (var-get artwork-nonce) u1))
      (total-shares (fold + (map get-share collaborators) u0))
    )
    (asserts! (<= royalty-percentage u100) ERR-INVALID-PERCENTAGE)
    (asserts! (is-eq total-shares u100) ERR-INVALID-PERCENTAGE)
    (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)

    (try! (nft-mint? artwork artwork-id tx-sender))
    (map-set artwork-details
      { artwork-id: artwork-id }
      {
        creator: tx-sender,
        owner: tx-sender,
        price: price,
        royalty-percentage: royalty-percentage,
        is-listed: false
      }
    )
    (map-set creator-collaborators
      { artwork-id: artwork-id }
      { collaborators: collaborators }
    )
    (var-set artwork-nonce artwork-id)
    (ok artwork-id)
  )
)

(define-private (get-share (collaborator { address: principal, share: uint }))
  (get share collaborator)
)

(define-public (list-artwork (artwork-id uint) (new-price uint))
  (let
    (
      (artwork-info (unwrap! (get-artwork-details artwork-id) ERR-NOT-LISTED))
    )
    (asserts! (is-eq (get owner artwork-info) tx-sender) ERR-NOT-OWNER)
    (asserts! (not (get is-listed artwork-info)) ERR-ALREADY-LISTED)
    (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)

    (map-set artwork-details
      { artwork-id: artwork-id }
      (merge artwork-info { price: new-price, is-listed: true })
    )
    (ok true)
  )
)

(define-public (unlist-artwork (artwork-id uint))
  (let
    (
      (artwork-info (unwrap! (get-artwork-details artwork-id) ERR-NOT-LISTED))
    )
    (asserts! (is-eq (get owner artwork-info) tx-sender) ERR-NOT-OWNER)
    (asserts! (get is-listed artwork-info) ERR-NOT-LISTED)
    (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)

    (map-set artwork-details
      { artwork-id: artwork-id }
      (merge artwork-info { is-listed: false })
    )
    (ok true)
  )
)

(define-public (purchase-artwork (artwork-id uint))
  (let
    (
      (artwork-info (unwrap! (get-artwork-details artwork-id) ERR-NOT-LISTED))
      (creator-info (unwrap! (get-collaborators artwork-id) ERR-NOT-LISTED))
      (price (get price artwork-info))
      (royalty-amount (/ (* price (get royalty-percentage artwork-info)) u100))
      (seller-amount (- price royalty-amount))
    )
    (asserts! (get is-listed artwork-info) ERR-NOT-LISTED)
    (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)

    (try! (stx-transfer? price tx-sender (get owner artwork-info)))
    (try! (distribute-royalties artwork-id royalty-amount creator-info))
    
    (try! (nft-transfer? artwork artwork-id (get owner artwork-info) tx-sender))
    (map-set artwork-details
      { artwork-id: artwork-id }
      (merge artwork-info { owner: tx-sender, is-listed: false })
    )
    (ok true)
  )
)

(define-data-var current-artwork-id uint u0)

(define-private (distribute-royalties (artwork-id uint) (royalty-amount uint) (creator-info { collaborators: (list 10 { address: principal, share: uint }) }))
  (begin
    (var-set current-artwork-id artwork-id)
    (fold distribute-share (get collaborators creator-info) (ok royalty-amount))
  )
)

(define-private (record-royalty-payment (artwork-id uint) (recipient principal) (amount uint))
  (let
    (
      (payment-id (+ (var-get payment-nonce) u1))
      (current-history (default-to 
        { payment-ids: (list), total-earned: u0 }
        (get-recipient-history recipient artwork-id)
      ))
      (updated-payment-ids (unwrap! (as-max-len? (append (get payment-ids current-history) payment-id) u50) (err u1)))
      (updated-total (+ (get total-earned current-history) amount))
    )
    (map-set royalty-payments
      { payment-id: payment-id }
      {
        artwork-id: artwork-id,
        recipient: recipient,
        amount: amount,
        block-height: burn-block-height,
        transaction-sender: tx-sender
      }
    )
    (map-set recipient-payment-history
      { recipient: recipient, artwork-id: artwork-id }
      { payment-ids: updated-payment-ids, total-earned: updated-total }
    )
    (var-set payment-nonce payment-id)
    (ok payment-id)
  )
)

(define-private (distribute-share (collaborator { address: principal, share: uint }) (previous-result (response uint uint)))
  (match previous-result
    result (let
      (
        (amount (/ (* result (get share collaborator)) u100))
        (recipient-address (get address collaborator))
        (artwork-id (var-get current-artwork-id))
      )
      (if (> amount u0)
        (match (stx-transfer? amount tx-sender recipient-address)
          success (begin
            (unwrap-panic (record-royalty-payment artwork-id recipient-address amount))
            (ok (- result amount))
          )
          error (err u1)
        )
        (ok result)
      )
    )
    error (err error)
  )
)
(define-public (pause-contract)
  (begin
    (var-set contract-paused true)
    (ok true)
  )
)

(define-public (unpause-contract)
  (begin
    (var-set contract-paused false)
    (ok true)
  )
)