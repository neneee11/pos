/* Build amount-specific Thai PromptPay QR payloads from the shop's existing mobile PromptPay ID. */
(function () {
  "use strict";

  const tlv = (tag, value) => tag + String(value.length).padStart(2, "0") + value;

  function crc16(payload) {
    let crc = 0xffff;
    for (let i = 0; i < payload.length; i++) {
      crc ^= payload.charCodeAt(i) << 8;
      for (let bit = 0; bit < 8; bit++) crc = crc & 0x8000 ? (crc << 1) ^ 0x1021 : crc << 1;
      crc &= 0xffff;
    }
    return crc.toString(16).toUpperCase().padStart(4, "0");
  }

  window.promptPayPayload = function (amount) {
    const value = Number(amount);
    const account = String(window.YUMDIWA_CONFIG?.PROMPTPAY_ID || "").replace(/\D/g, "");
    if (!Number.isFinite(value) || value <= 0 || !/^0066\d{9}$/.test(account)) {
      throw new Error("PromptPay amount or recipient is invalid");
    }
    const merchant = tlv("00", "A000000677010111") + tlv("01", account);
    const body = tlv("00", "01") + tlv("01", "12") + tlv("29", merchant) +
      tlv("53", "764") + tlv("54", value.toFixed(2)) + tlv("58", "TH");
    return body + "6304" + crc16(body + "6304");
  };

  window.renderPromptPayQr = function (canvas, amount) {
    if (!window.QRCode) throw new Error("QR generator did not load");
    canvas.replaceChildren();
    return new window.QRCode(canvas, {
      text: window.promptPayPayload(amount), width: 320, height: 320,
      colorDark: "#071c2e", colorLight: "#ffffff", correctLevel: window.QRCode.CorrectLevel.M
    });
  };
})();
