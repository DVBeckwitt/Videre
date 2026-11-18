package org.tartarus.snowball;


/**
 * Internal class used by Snowball stemmers
 */
public class Among {
    public Among (String s, int substring_i, int result) {
        this.s = s.toCharArray();
        this.substring_i = substring_i;
        this.result = result;
    }

    // Videre Android 7 compatibility: the seven pinned generated stemmers
    // use only this three-argument constructor. Unused MethodHandle callbacks
    // (API 26+) are deliberately not included.

    final char[] s; /* search string */
    final int substring_i; /* index to longest matching substring */
    final int result; /* result of the lookup */

}
