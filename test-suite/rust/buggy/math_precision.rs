fn bad_money() {
    let price = 0.1f32;
    let qty = 3f32;
    if price * qty == 0.3 { // equality on floats
        println!("exact");
    }
}

fn main() {
    bad_money();
}
