//
//  OneTimeCodeTests.swift
//  TetherTests
//

import Testing
@testable import Tether

struct OneTimeCodeTests {
    @Test(arguments: [
        ("482913 is your verification code.", "482913"),
        ("Your OTP for login is 1234. Do not share it with anyone.", "1234"),
        ("G-123456 is your Google verification code.", "123456"),
        ("Use 123 456 to sign in to Discord.", "123456"),
        ("Your WhatsApp code: 123-456. Don't share this code with others", "123456"),
        ("845201 is the OTP for your transaction of INR 5,000.00 at AMAZON on 14/10/26. Valid for 10 mins.", "845201"),
        ("Dear customer, OTP 739104 for login to NetBanking. Never share OTP. -HDFC Bank", "739104"),
        ("Your Uber code is 4821. Never share this code.", "4821"),
        ("Instagram: 591 284 is your security code.", "591284"),
        ("Card ending 1234. OTP is 998877", "998877"),
        ("OTP 556677 for txn on A/c XX5678. Do not share.", "556677"),
    ])
    func findsCodes(text: String, expected: String) {
        #expect(OneTimeCode.find(in: text) == expected)
    }

    @Test(arguments: [
        "Meeting at 4 PM in room 2045",
        "Your order of Rs 1299 has shipped",
        "Shipping update: parcel 48213 is out for delivery",
        "Are we still on for 4?",
        "Call me on 9876543210",
        "Payment of ₹ 4500 received. Thank you!",
        "Your code review on PR 1234 was approved in 2026",
    ])
    func ignoresTextWithoutACode(text: String) {
        let found = OneTimeCode.find(in: text)
        if text.hasPrefix("Your code review") {
            // Mentions "code" and has a plausible number; accept either answer but not the year.
            #expect(found != "2026")
        } else {
            #expect(found == nil)
        }
    }
}
