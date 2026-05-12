import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
    vus: 50,
    duration: '30s',
    thresholds: {
        http_req_duration: ['p(99)<10'], // p99 < 10ms for safety, goal is < 1ms
    },
};

const payload = JSON.stringify({
    "id": "tx-123",
    "transaction": {
        "amount": 100.0,
        "installments": 1,
        "requested_at": "2026-03-11T18:45:53Z"
    },
    "customer": {
        "avg_amount": 50.0,
        "tx_count_24h": 5,
        "known_merchants": ["MERC-001"]
    },
    "merchant": {
        "id": "MERC-001",
        "mcc": "5411",
        "avg_amount": 40.0
    },
    "terminal": {
        "is_online": true,
        "card_present": true,
        "km_from_home": 10.5
    },
    "last_transaction": null
});

const params = {
    headers: {
        'Content-Type': 'application/json',
    },
};

export default function () {
    const res = http.post('http://localhost:9999/fraud-score', payload, params);
    check(res, {
        'status is 200': (r) => r.status === 200,
        'has approved field': (r) => r.json().hasOwnProperty('approved'),
    });
}
