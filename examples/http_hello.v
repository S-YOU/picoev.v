import picoev

pub fn callback(req byteptr) string {
	return 'Hello, World!'
}

pub fn main() {
	picoev.new(8080, &callback).serve()
}
