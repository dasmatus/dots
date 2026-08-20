use crate::change::ToChange;
mod cf;
mod change;
fn main() {
    loop {
        ToChange::run();
    }
}
