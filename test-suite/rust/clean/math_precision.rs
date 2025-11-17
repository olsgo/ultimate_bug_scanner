fn precise_money() {
    let price_cents = 10i64;
    let qty = 3i64;
    let total = price_cents * qty;
    println!("{} cents", total);
}

fn main() {
    precise_money();
}
