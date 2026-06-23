import http from "k6/http";
import { check, sleep } from "k6";
import { randomIntBetween } from "https://jslib.k6.io/k6-utils/1.2.0/index.js";

// Configuration for simulating 100 concurrent vehicles sending telemetry
export const options = {
  stages: [
    { duration: "30s", target: 50 }, // Ramp up to 50 vehicles
    { duration: "1m", target: 20 }, // Maintain 100 vehicles
    { duration: "30s", target: 0 }, // Ramp down
  ],
};

const BASE_URL = __ENV.BASE_URL || "http://localhost:3002/telemetry/ingest";
const VEHICLE_PREFIX = "VEH-";

export default function () {
  // Simulate a specific vehicle based on the virtual user ID (VU)
  const vehicleId = `${VEHICLE_PREFIX}${__VU}`;

  // Random coordinates near Bogotá
  const lat = 4.6097 + (Math.random() - 0.5) * 0.1;
  const lng = -74.0817 + (Math.random() - 0.5) * 0.1;

  // 5% chance to simulate an error (e.g. malformed payload)
  const injectError = Math.random() < 0.05;

  // 10% chance to simulate duplicate or delayed data
  const injectDuplicate = Math.random() < 0.1;

  const payload = {
    vehicleId: vehicleId,
    latitude: injectError ? "INVALID_LAT" : lat,
    longitude: lng,
    speed: randomIntBetween(0, 140), // Speeds > 120 will trigger OVERSPEED anomaly
    engineRpm: randomIntBetween(800, 4000),
    fuelLevel: randomIntBetween(2, 100), // Fuel < 10 will trigger LOW_FUEL anomaly
  };

  const params = {
    headers: { "Content-Type": "application/json" },
  };

  // Send request
  const res = http.post(BASE_URL, JSON.stringify(payload), params);

  // If we inject a duplicate, immediately send the exact same payload again
  if (injectDuplicate && !injectError) {
    http.post(BASE_URL, JSON.stringify(payload), params);
  }

  // Verify response
  if (!injectError) {
    check(res, {
      "status is 202": (r) => r.status === 202,
    });
  } else {
    check(res, {
      "status is 400 (Bad Request)": (r) => r.status === 400,
    });
  }

  // Wait 2-5 seconds before sending next GPS ping
  sleep(randomIntBetween(2, 5));
}
