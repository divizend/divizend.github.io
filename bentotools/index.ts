import type { Email } from "bentotools";

export default {
  reverser: (email: Email) => email.text!.split("").reverse().join(""),
};
