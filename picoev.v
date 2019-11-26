// Copyright (c) 2019 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module picoev

import net

#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>

#flag -I @VMOD/syou/picoev
#flag @VMOD/syou/picoev/picoev.o
#include "src/picoev.h"

/*
import const (
	PICOEV_READ
	PICOEV_TIMEOUT

	F_SETFL
	O_NONBLOCK
	O_CLOEXEC

	IPPROTO_TCP

	TCP_NODELAY
	TCP_QUICKACK
	TCP_DEFER_ACCEPT
	TCP_FASTOPEN

	EAGAIN
	EWOULDBLOCK

	NULL
)
*/

const (
	MaxFds = 1024
	TIMEOUT_SECS = 10
)

struct C.picoev_loop {
	loop_id u16
	timeout C.timeout
	now i64
}

struct Picoev {
	loop *C.picoev_loop
	cb fn(res byteptr) string
}

fn C.fcntl() int
fn C.picoev_del() int
fn C.picoev_set_timeout()
fn C.picoev_add()
fn C.write() int
fn C.picoev_init() int
fn C.picoev_deinit() int
fn C.picoev_create_loop() int
fn C.picoev_loop_once() int
fn C.picoev_destroy_loop() int
//fn C.accept() int

pub fn setup_sock(fd int) {
	on := int(1)
	C.setsockopt(fd, C.IPPROTO_TCP, C.TCP_NODELAY, &on, sizeof(int))
	C.fcntl(fd, C.F_SETFL, C.O_NONBLOCK) == 0
}

pub fn close_conn(loop *C.picoev_loop, fd int) {
	C.picoev_del(loop, fd)
	C.close(fd)
}

fn rw_callback(loop *C.picoev_loop, fd, events int, cb_arg voidptr) {
	if (events & C.PICOEV_TIMEOUT) != 0 {
		close_conn(loop, fd)
	} else if (events & C.PICOEV_READ) != 0 {
		buf := [1536]byte
		C.picoev_set_timeout(loop, fd, C.TIMEOUT_SECS)
		r := C.read(fd, buf, 1024)
		match r {
		0 {
			close_conn(loop, fd)
		}
		-1 {
			if errno == C.EAGAIN || errno == C.EWOULDBLOCK {
				//
			} else {
				close_conn(loop, fd)
			}
		}
		else {
			p := *Picoev(cb_arg)
			cb := p.cb
			res := cb(buf)

			mut response := 'HTTP/1.1 200 OK\r\nContent-Length: $res.len\r\n\r\n'
			response += res

			if C.write(fd, response.str, response.len) != response.len {
				close_conn(loop, fd)
			}
		}
		}
	}
}

fn accept_callback(loop *C.picoev_loop, fd, events int, cb_arg voidptr) {
	newfd := C.accept(fd, 0, 0)
	if newfd != -1 {
		setup_sock(newfd)
		C.picoev_add(loop, newfd, C.PICOEV_READ, C.TIMEOUT_SECS,
			rw_callback, cb_arg)
	}
}

pub fn new(port int, cb voidptr) &Picoev {
	sock := net.new_socket(C.AF_INET, C.SOCK_STREAM, 0) or { panic(err) }
	assert sock.sockfd != -1

	flag := int(1)
	assert C.setsockopt(sock.sockfd, C.SOL_SOCKET, C.SO_REUSEADDR, &flag, 8) == 0
	assert C.setsockopt(sock.sockfd, C.SOL_SOCKET, C.SO_REUSEPORT, &flag, 8) == 0
	$if linux {
		assert C.setsockopt(sock.sockfd, C.IPPROTO_TCP, C.TCP_QUICKACK, &flag, 8) == 0
		timeout := int(10)
		assert C.setsockopt(sock.sockfd, C.IPPROTO_TCP, C.TCP_DEFER_ACCEPT, &timeout, 8) == 0
		queue_len := int(4096)
		assert C.setsockopt(sock.sockfd, C.IPPROTO_TCP, C.TCP_FASTOPEN, &queue_len, 8) == 0
	}

	bind_res := sock.bind(port) or { panic(err) }
	assert bind_res == 0

	listen_res := sock.listen() or { panic(err) }
	assert listen_res == 0

	setup_sock(sock.sockfd)

	C.picoev_init(MaxFds)
	loop := C.picoev_create_loop(60)

	picoev := &Picoev {
		loop: loop,
		cb: cb
	}
	C.picoev_add(loop, sock.sockfd, C.PICOEV_READ, 0, accept_callback, picoev)

	return picoev
}

pub fn (p Picoev) serve() {
	for {
		C.picoev_loop_once(p.loop, 0)
	}
}

pub fn (p Picoev) destroy() {
	C.picoev_destroy_loop(p.loop)
	C.picoev_deinit()
}
